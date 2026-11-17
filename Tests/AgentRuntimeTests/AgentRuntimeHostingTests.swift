import AgentCore
import Foundation
import XCTest
@testable import AgentRuntime

/// A provider whose stop takes as long as a write to a provider that stopped reading.
private final class SlowStoppingRuntime: AgentSessionRuntime, @unchecked Sendable {
    let callback: @Sendable (AgentRuntimeEvent) -> Void
    let stopDelay: TimeInterval
    private let lock = NSLock()
    private var stoppedInTask: [Bool] = []
    var stops: [Bool] { lock.withLock { stoppedInTask } }

    init(stopDelay: TimeInterval, _ callback: @escaping @Sendable (AgentRuntimeEvent) -> Void) {
        self.stopDelay = stopDelay; self.callback = callback
    }
    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?) async throws {
        callback(.providerSession("provider-\(UUID())"))
        callback(.status(.idle))
    }
    func approve(request: String, allow: Bool) async throws {}
    func setAlwaysAllowed(_ tools: Set<String>) async throws {}
    func setAccess(_ mode: AgentAccessMode) async throws {}
    func interrupt() async throws { callback(.status(.idle)) }
    func stop() {
        let inTask = withUnsafeCurrentTask { $0 != nil }
        Thread.sleep(forTimeInterval: stopDelay)
        lock.withLock { stoppedInTask.append(inTask) }
    }
}

/// A provider whose stop returns at once, as the real one does after SIGTERM, but which
/// exits only once the test lets it: retirement must keep it until then.
private final class LingeringRuntime: AgentSessionRuntime, @unchecked Sendable {
    let callback: @Sendable (AgentRuntimeEvent) -> Void
    private let state = NSCondition()
    private var terminating = false, mayExit = false, exited = false
    var isTerminating: Bool { state.withLock { terminating } }
    var hasExited: Bool { state.withLock { exited } }
    init(_ callback: @escaping @Sendable (AgentRuntimeEvent) -> Void) { self.callback = callback }
    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?) async throws {
        callback(.providerSession("lingering")); callback(.status(.idle))
    }
    func approve(request: String, allow: Bool) async throws {}
    func setAlwaysAllowed(_ tools: Set<String>) async throws {}
    func setAccess(_ mode: AgentAccessMode) async throws {}
    func interrupt() async throws {}
    func stop() {}
    func terminate() {
        state.withLock {
            terminating = true
            while !mayExit { state.wait() }
            exited = true
        }
    }
    func exit() {
        state.withLock { mayExit = true; state.broadcast() }
    }
}

private final class RuntimeListOf<Runtime: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Runtime] = []
    var values: [Runtime] { lock.withLock { list } }
    func append(_ runtime: Runtime) { lock.withLock { list.append(runtime) } }
}

private final class RuntimeList: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [SlowStoppingRuntime] = []
    var values: [SlowStoppingRuntime] { lock.withLock { list } }
    func append(_ runtime: SlowStoppingRuntime) { lock.withLock { list.append(runtime) } }
}

private final class Messages: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    var values: [String] { lock.withLock { list } }
    func append(_ message: String) { lock.withLock { list.append(message) } }
}

/// What a host embedding the runtime in a server relies on: retiring a provider never
/// holds a cooperative thread, shutdown is bounded by the slowest provider, errors reach
/// the host's log, and a store the runtime cannot lock still serves its conversations.
final class AgentRuntimeHostingTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-hosting-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func wait(_ description: String, timeout: TimeInterval = 5, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out: \(description)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testClosingAConversationStopsItsProviderOffTheCooperativePool() async throws {
        let root = try root(), runtimes = RuntimeList()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = SlowStoppingRuntime(stopDelay: 1, callback)
            runtimes.append(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.send(session: id, text: "Start", model: nil))
        let started = Date()
        _ = try await sessions.handle(.close(session: id))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "Closing must not wait for the provider to stop")
        try await wait("provider stopped") { runtimes.values.first?.stops.isEmpty == false }
        XCTAssertEqual(runtimes.values.first?.stops, [false], "The slow stop ran on a dispatch worker, not in a Swift task")
    }

    func testShutdownStopsEveryProviderTogether() async throws {
        let root = try root(), runtimes = RuntimeList()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = SlowStoppingRuntime(stopDelay: 0.6, callback)
            runtimes.append(runtime)
            return runtime
        })
        for _ in 0..<4 {
            let id = SessionId()
            _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
            _ = try await sessions.handle(.send(session: id, text: "Start", model: nil))
        }
        XCTAssertEqual(runtimes.values.count, 4)
        let started = Date()
        sessions.shutdown()
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(runtimes.values.map(\.stops.count), [1, 1, 1, 1], "Shutdown returns after every provider stopped")
        XCTAssertLessThan(elapsed, 1.8, "Four 0.6 s stops in sequence would take 2.4 s")
    }

    func testRuntimeErrorsReachTheHostsHandler() throws {
        let root = try root(), storage = root.appendingPathComponent("agents"), messages = Messages()
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let session = SessionId()
        try Data("{ not a conversation".utf8).write(to: storage.appendingPathComponent("\(session).json"))
        AgentRuntimeLog.setErrorHandler { messages.append($0) }
        defer { AgentRuntimeLog.setErrorHandler(nil) }
        let service = try AgentRuntimeService(storageDirectory: storage, home: root, projectDirectory: { _ in root })
        service.shutdown()
        XCTAssertTrue(messages.values.contains { $0.contains(session.description) }, "\(messages.values)")
        AgentRuntimeLog.setErrorHandler(nil)
        let before = messages.values.count
        let again = try AgentRuntimeService(storageDirectory: storage, home: root, projectDirectory: { _ in root })
        again.shutdown()
        XCTAssertEqual(messages.values.count, before, "A removed handler receives nothing")
    }

    func testAStoreTheRuntimeCannotLockStillServesItsConversations() async throws {
        try XCTSkipIf(geteuid() == 0, "Root ignores file permissions")
        let root = try root(), storage = root.appendingPathComponent("agents"), messages = Messages()
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let project = ProjectId(), session = SessionId()
        let saved = AgentChatSnapshot(session: session, project: project, provider: .claude, revision: 3,
                                      items: [.init(id: "kept", kind: .user, text: "Saved before the folder became read-only")])
        let snapshot = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved))
        try JSONSerialization.data(withJSONObject: ["snapshot": snapshot, "directory": root.path])
            .write(to: storage.appendingPathComponent("\(session).json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: storage.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storage.path) }
        AgentRuntimeLog.setErrorHandler { messages.append($0) }
        defer { AgentRuntimeLog.setErrorHandler(nil) }

        XCTAssertThrowsError(try AgentRuntimeService(storageDirectory: storage, home: root, projectDirectory: { _ in root }),
                             "Without the host's ownership, a store the runtime can't lock is refused")
        let service = try AgentRuntimeService(storageDirectory: storage, home: root, hostOwnsStore: true, projectDirectory: { _ in root })
        defer { service.shutdown() }
        let restored = try await service.handle(.read(session: session))
        XCTAssertEqual(restored.items, saved.items)
        XCTAssertTrue(messages.values.contains { $0.contains("without exclusive ownership") }, "\(messages.values)")
    }

    func testASecondOwnerOfTheStoreIsStillRefused() throws {
        let storage = try root().appendingPathComponent("agents")
        let first = try AgentRuntimeService(storageDirectory: storage, projectDirectory: { _ in storage })
        defer { first.shutdown() }
        XCTAssertThrowsError(try AgentRuntimeService(storageDirectory: storage, projectDirectory: { _ in storage })) { error in
            XCTAssertEqual(error as? FileLock.Failure, .held)
        }
    }

    /// Version managers such as nvm add provider folders after the server started;
    /// discovery finds a CLI installed there, as a new conversation does.
    func testCommandDiscoverySearchesFoldersAddedAfterLaunch() async throws {
        let root = try root(), project = ProjectId()
        let folder = root.appendingPathComponent("project"), installed = root.appendingPathComponent("installed-later")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let service = try AgentRuntimeService(storageDirectory: root.appendingPathComponent("agents"), home: root,
                                              projectDirectory: { _ in folder })
        defer { service.shutdown() }

        let marker = root.appendingPathComponent("discovered")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        let codex = installed.appendingPathComponent("codex")
        try "#!/bin/sh\ntouch '\(marker.path)'\nexit 1\n".write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", installed.path + ":" + path, 1)
        defer { setenv("PATH", path, 1) }

        _ = try await service.composerContext(.init(project: project, provider: .codex, forceRefresh: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "Discovery ran the CLI installed after launch")
    }

    func testTextCutInsideACharacterReadsAsItsWholeCharacters() {
        let wide = Data(String(repeating: "├", count: 4).utf8)   // three bytes each
        XCTAssertEqual(AgentReplyBounds.wholeCharacters(wide.dropFirst()), String(repeating: "├", count: 3), "Cut at the start")
        XCTAssertEqual(AgentReplyBounds.wholeCharacters(wide.dropLast()), String(repeating: "├", count: 3), "Cut at the end")
        XCTAssertEqual(AgentReplyBounds.wholeCharacters(wide.dropFirst(2).dropLast(2)), "├├")
        XCTAssertEqual(AgentReplyBounds.wholeCharacters(Data("a😀".utf8).dropLast(3)), "a", "A four-byte character")
        XCTAssertEqual(AgentReplyBounds.wholeCharacters(wide), String(repeating: "├", count: 4))
        XCTAssertEqual(AgentReplyBounds.wholeCharacters(Data()), "")
        XCTAssertEqual(AgentReplyBounds.wholeCharacters(Data([0x80, 0x80])), "")
    }

    func testReplyTextIsCutBetweenCharactersWithinBothLimits() {
        let wide = String(repeating: "├", count: 10)   // three bytes each
        let start = AgentReplyBounds.bounded(wide, maximumBytes: 10, maximumEncodedBytes: 1000, keepingEnd: false)
        XCTAssertEqual(start.text, String(repeating: "├", count: 3))
        XCTAssertTrue(start.cut)
        let end = AgentReplyBounds.bounded("x" + wide, maximumBytes: 10, maximumEncodedBytes: 1000, keepingEnd: true)
        XCTAssertEqual(end.text, String(repeating: "├", count: 3))
        let control = AgentReplyBounds.bounded(String(repeating: "\u{1}", count: 100), maximumBytes: 1000, maximumEncodedBytes: 60, keepingEnd: false)
        XCTAssertEqual(control.text.utf8.count, 10, "Six bytes each once escaped")
        let fits = AgentReplyBounds.bounded("plain \"quoted\" text", maximumBytes: 1000, maximumEncodedBytes: 1000, keepingEnd: true)
        XCTAssertEqual(fits.text, "plain \"quoted\" text")
        XCTAssertFalse(fits.cut)
    }

    /// A kept output that ended inside a character grew past its limit when decoded, and
    /// control characters escaped past a frame: either reply failed to reach the client.
    func testWholeToolOutputFitsItsReplyWhateverItHolds() async throws {
        let root = try root(), runtimes = RuntimeList()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = SlowStoppingRuntime(stopDelay: 0, callback)
            runtimes.append(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: session, text: "go", model: nil))
        let runtime = try XCTUnwrap(runtimes.values.first)
        let wide = String(repeating: "├", count: 1_500_000), control = String(repeating: "\u{1}", count: 4_500_000)
        runtime.callback(.item(AgentChatItem(id: "wide", kind: .tool, text: "Bash",
            tool: .init(name: "Bash", category: .command, input: "cat", output: "start" + wide, status: .completed, presentation: .command))))
        runtime.callback(.item(AgentChatItem(id: "control", kind: .tool, text: "Read",
            tool: .init(name: "Read", category: .read, input: "{}", output: "start" + control, status: .completed))))
        runtime.callback(.status(.idle))

        for item in ["wide", "control"] {
            var reply: AgentConversationReply?
            for _ in 0..<250 where reply == nil {
                reply = try? await sessions.conversation(.toolOutput(session: session, item: item))
                if reply == nil { try await Task.sleep(for: .milliseconds(20)) }
            }
            guard case .toolOutput(let output) = try XCTUnwrap(reply, "\(item) was not kept") else { return XCTFail("Unexpected reply") }
            XCTAssertTrue(output.truncated, item)
            XCTAssertFalse(output.text.contains("\u{FFFD}"), "\(item) gained replacement characters")
            XCTAssertLessThanOrEqual(output.text.utf8.count, AgentToolOutput.maximumBytes, item)
            XCTAssertNoThrow(try AgentConversationReply.toolOutput(output).validate(), item)
            let encoded = try WireJSON.encode(AgentConversationReply.toolOutput(output)).count
            XCTAssertLessThanOrEqual(encoded, AgentToolOutput.maximumEncodedBytes + 1024, "\(item) fits a frame")
            if item == "wide" { XCTAssertTrue(output.text.hasSuffix("├"), "A command keeps its end") }
            else { XCTAssertTrue(output.text.hasPrefix("start"), "A read keeps its start") }
        }
    }

    private func command(_ id: String, output: String) -> AgentChatItem {
        AgentChatItem(id: id, kind: .tool, text: "Bash",
                      tool: .init(name: "Bash", category: .command, input: "cat", output: output, status: .completed, presentation: .command))
    }

    private func read(_ id: String, output: String) -> AgentChatItem {
        AgentChatItem(id: id, kind: .tool, text: "Read", tool: .init(name: "Read", category: .read, input: "{}", output: output, status: .completed))
    }

    /// A finished turn whose provider reported `items`.
    private func conversation(reporting items: [AgentChatItem], in root: URL) async throws -> (AgentSessions, SessionId) {
        let runtimes = RuntimeList()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = SlowStoppingRuntime(stopDelay: 0, callback)
            runtimes.append(runtime)
            return runtime
        })
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: session, text: "go", model: nil))
        let runtime = try XCTUnwrap(runtimes.values.first)
        for item in items { runtime.callback(.item(item)) }
        runtime.callback(.status(.idle))
        return (sessions, session)
    }

    /// The file "Show full output" reads, once written.
    private func keptOutput(_ root: URL, _ session: SessionId, _ item: String) async throws -> URL {
        let file = root.appendingPathComponent("outputs/\(session)/" + AgentToolImages.directoryName(item: item) + ".txt")
        try await wait("\(item) kept") { FileManager.default.fileExists(atPath: file.path) }
        return file
    }

    /// What is kept is within the reply's limits on disk, cut between characters, with the
    /// end a command needs or the start of anything else, so reading need not trim it.
    func testKeptToolOutputIsStoredWithinItsReplyLimits() async throws {
        let root = try root()
        let wide = "START" + String(repeating: "├", count: 1_500_000) + "END"
        let control = "START" + String(repeating: "\u{1}", count: 4_500_000) + "END"
        let (sessions, session) = try await conversation(reporting: [command("wide", output: wide), read("control", output: control)], in: root)
        defer { sessions.shutdown() }
        for (item, keepsEnd) in [("wide", true), ("control", false)] {
            let data = try Data(contentsOf: try await keptOutput(root, session, item))
            let text = try XCTUnwrap(String(data: data, encoding: .utf8), "\(item) holds whole characters")
            XCTAssertLessThanOrEqual(data.count, AgentToolOutput.maximumBytes, item)
            XCTAssertLessThanOrEqual(data.reduce(0) { $0 + AgentReplyBounds.encodedSize($1) }, AgentToolOutput.maximumEncodedBytes, item)
            XCTAssertGreaterThan(data.count, AgentToolOutput.maximumEncodedBytes / 6 - 8, "\(item) keeps as much as fits")
            if keepsEnd { XCTAssertTrue(text.hasSuffix("END") && !text.hasPrefix("START"), "A command keeps its end") }
            else { XCTAssertTrue(text.hasPrefix("START") && !text.hasSuffix("END"), "A read keeps its start") }
        }
    }

    /// Earlier versions kept outputs cut inside a character, and outputs that escape past
    /// a frame; reading such a file still answers within the reply's limits, in whole
    /// characters even when the cut file is shorter than the limit.
    func testOutputsKeptByEarlierVersionsAreBoundedWhenRead() async throws {
        let root = try root(), small = String(repeating: "x", count: 20_000)
        let (sessions, session) = try await conversation(reporting: [command("wide-end", output: small), read("wide-start", output: small),
                                                                     read("control", output: small), read("cut", output: small)], in: root)
        defer { sessions.shutdown() }
        let wide = Data(("START" + String(repeating: "├", count: 1_500_000) + "END").utf8)
        let legacy = ["wide-end": wide.suffix(AgentToolOutput.maximumBytes), "wide-start": wide.prefix(AgentToolOutput.maximumBytes),
                      "control": Data(String(repeating: "\u{1}", count: AgentToolOutput.maximumBytes).utf8),
                      "cut": Data(String(repeating: "├", count: 10_000).utf8).dropFirst().dropLast()]
        for (item, data) in legacy { try Data(data).write(to: try await keptOutput(root, session, item)) }

        for item in legacy.keys.sorted() {
            guard case .toolOutput(let output) = try await sessions.conversation(.toolOutput(session: session, item: item)) else {
                return XCTFail("Unexpected reply")
            }
            XCTAssertEqual(output.item, item)
            XCTAssertFalse(output.text.isEmpty, item)
            XCTAssertFalse(output.text.contains("\u{FFFD}"), "\(item) gained replacement characters")
            XCTAssertLessThanOrEqual(output.text.utf8.count, AgentToolOutput.maximumBytes, item)
            XCTAssertLessThanOrEqual(try WireJSON.encode(AgentConversationReply.toolOutput(output)).count,
                                     AgentToolOutput.maximumEncodedBytes + 1024, "\(item) fits a frame")
            if item == "cut" { XCTAssertEqual(output.text, String(repeating: "├", count: 9_998)) }
        }
    }

    /// A provider that ignores SIGTERM outlived a host that exited before the
    /// scheduled SIGKILL; waiting for its exit kills it in time.
    func testAProviderThatIgnoresTerminationIsKilledBeforeTheHostMovesOn() throws {
        let root = try root(), started = root.appendingPathComponent("started")
        let process = try AgentProcess(launch: .init(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; echo $$ > '\(started.path)'; while :; do sleep 0.05; done"],
            environment: ProcessInfo.processInfo.environment),
            directory: root.path, onLine: { _ in }, onExit: { _, _ in })
        var pid: pid_t = 0
        for _ in 0..<200 where pid == 0 {
            pid = pid_t((try? String(contentsOf: started, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            if pid == 0 { usleep(10_000) }
        }
        XCTAssertGreaterThan(pid, 0)
        process.stop()
        let started2 = Date()
        process.waitForExit(grace: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(started2), 2)
        XCTAssertNotEqual(kill(pid, 0), 0, "The provider is gone once the wait returns")
    }

    func testShutdownWaitsForProvidersStillStoppingAfterTheirConversationClosed() async throws {
        let root = try root(), runtimes = RuntimeList()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = SlowStoppingRuntime(stopDelay: 0.8, callback)
            runtimes.append(runtime)
            return runtime
        })
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.send(session: id, text: "Start", model: nil))
        _ = try await sessions.handle(.close(session: id))
        sessions.shutdown()
        XCTAssertFalse(runtimes.values.first?.stops.isEmpty ?? true, "Shutdown returned before the closed conversation's provider stopped")
    }

    func testALockFileTheRuntimeCannotOpenInAWritableStoreIsStillRefused() throws {
        try XCTSkipIf(geteuid() == 0, "Root ignores file permissions")
        let storage = try root().appendingPathComponent("agents")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let lock = storage.appendingPathComponent("runtime.lock")
        try Data().write(to: lock)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lock.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lock.path) }
        XCTAssertThrowsError(try AgentRuntimeService(storageDirectory: storage, projectDirectory: { _ in storage }),
                             "A writable store must not be served without its lock: another owner may hold it")
    }

    func testShutdownWaitsForARetiredProviderStillExitingAfterItsStopReturned() async throws {
        let root = try root(), runtimes = RuntimeListOf<LingeringRuntime>()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = LingeringRuntime(callback)
            runtimes.append(runtime)
            return runtime
        })
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.send(session: id, text: "Start", model: nil))
        _ = try await sessions.handle(.close(session: id))
        let runtime = try XCTUnwrap(runtimes.values.first)
        try await wait("retirement waits for the provider to exit") { runtime.isTerminating }

        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { sessions.shutdown(); stopped.signal() }
        XCTAssertEqual(stopped.wait(timeout: .now() + 0.3), .timedOut, "Shutdown returned while the retired provider was still running")
        runtime.exit()
        XCTAssertEqual(stopped.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(runtime.hasExited)
    }

    /// A Claude restart for a new model or effort replaces the provider process; the old
    /// one, if it ignores SIGTERM, must not outlive the runtime's termination.
    func testReplacedProviderProcessesAreKilledWhenTheRuntimeTerminates() async throws {
        let fixture = try AgentRuntimeFixture(#"""
        trap '' TERM
        echo $$ >> "$log.pids"
        take
        id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"request_id":"([^"]+)".*/\1/')
        emit "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"$id\",\"response\":{}}}"
        take
        emit '{"type":"system","subtype":"init","session_id":"stubborn-session"}'
        emit '{"type":"assistant","message":{"id":"answer","content":[{"type":"text","text":"Done"}]}}'
        emit '{"type":"result","subtype":"success","is_error":false,"result":"Done"}'
        hold
        while :; do sleep 0.05; done
        """#)
        defer { fixture.remove() }
        let recorder = AgentRuntimeRecorder()
        let runtime = fixture.runtime(.claude, recorder: recorder, resume: "original-session")
        for model in ["claude-opus-5-5", "claude-sonnet-5-5"] {
            let idle = expectation(description: "turn completed")
            recorder.observe = { event in if case .status(.idle) = event { idle.fulfill() } }
            try await runtime.send(text: "continue", model: model, reasoningEffort: nil)
            await fulfillment(of: [idle], timeout: 5)
        }
        XCTAssertEqual(runtime.replaced.count, 1, "The replaced provider stays tracked until it exits")
        runtime.terminate()
        let pids = try String(contentsOfFile: fixture.log.path + ".pids", encoding: .utf8)
            .split(separator: "\n").compactMap { pid_t($0) }
        XCTAssertEqual(pids.count, 2)
        for pid in pids { XCTAssertNotEqual(kill(pid, 0), 0, "Provider \(pid) outlived the runtime") }
    }

    /// A provider CLI that ignores SIGTERM and records its process ids.
    private func stubbornProvider(_ root: URL, answering answers: String = "") throws -> (executable: URL, pids: () -> [pid_t]) {
        let pids = root.appendingPathComponent("pids")
        let executable = root.appendingPathComponent("provider")
        try "#!/bin/sh\ntrap '' TERM\necho $$ >> '\(pids.path)'\n\(answers)\nwhile :; do sleep 0.05; done\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (executable, {
            ((try? String(contentsOf: pids, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { pid_t($0) }
        })
    }

    /// No conversation owns a model discovery: shutdown must still end its provider, and
    /// start no other after it.
    func testShutdownEndsAModelDiscoveryStillRunning() async throws {
        let root = try root(), provider = try stubbornProvider(root)
        // Its own Codex home, so no cached catalog stands in for the one discovery would find.
        let service = try AgentRuntimeService(storageDirectory: root.appendingPathComponent("agents"), home: root,
                                              executables: [.codex: provider.executable],
                                              environment: ["CODEX_HOME": root.appendingPathComponent("codex-home").path],
                                              projectDirectory: { _ in root })
        let request = AgentModelCatalogRequest(project: ProjectId(), provider: .codex, forceRefresh: true)
        let discovery = Task { try await service.modelCatalog(request) }
        try await wait("the discovery started") { provider.pids().count == 1 }

        let started = Date()
        await Task.detached { service.shutdown() }.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let pid = try XCTUnwrap(provider.pids().first)
        XCTAssertNotEqual(kill(pid, 0), 0, "The discovery's provider outlived shutdown")
        let reply = try await discovery.value
        XCTAssertTrue(reply.models.isEmpty)

        _ = try await service.modelCatalog(request)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(provider.pids().count, 1, "No provider starts after shutdown")
    }

    /// A command discovery stops its provider once it answered; one that ignores the request
    /// must still be gone when shutdown returns, not a second later.
    func testShutdownEndsACommandDiscoveryProviderStillExiting() async throws {
        let root = try root()
        let provider = try stubbornProvider(root, answering: """
        read line; echo '{"id":1,"result":{}}'
        read line; read line; echo '{"id":2,"result":{"data":[]}}'
        """)
        let service = try AgentRuntimeService(storageDirectory: root.appendingPathComponent("agents"), home: root,
                                              executables: [.codex: provider.executable], projectDirectory: { _ in root })
        _ = try await service.composerContext(.init(project: ProjectId(), provider: .codex, forceRefresh: true))
        let pid = try XCTUnwrap(provider.pids().first)
        XCTAssertEqual(kill(pid, 0), 0, "The provider ignored its stop")

        await Task.detached { service.shutdown() }.value
        XCTAssertNotEqual(kill(pid, 0), 0, "The finished discovery's provider outlived shutdown")
    }

    /// Listing reads every provider transcript in the folder: it must run on a dispatch
    /// worker, never on one of Swift's cooperative threads.
    func testHistoryIsListedOffTheCooperativePool() async throws {
        let root = try root()
        let service = try AgentRuntimeService(storageDirectory: root.appendingPathComponent("agents"), home: root, projectDirectory: { _ in root })
        defer { service.shutdown() }
        let places = Messages()
        service.listHistory = { _, _ in
            places.append(withUnsafeCurrentTask { $0 == nil ? "worker" : "task" })
            return AgentHistoryReply(entries: [])
        }
        _ = try await service.history(.init(project: ProjectId()))
        XCTAssertEqual(places.values, ["worker"])
    }

    /// Closing a store's fence waits for the writes under way and admits none after, so
    /// nothing reaches the store once its next owner may hold it.
    func testAClosedFenceWaitsForWritesUnderWayAndAdmitsNoneAfter() {
        let fence = AgentStoreFence()
        let writing = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
        let closing = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { fence.write { writing.signal(); finish.wait() } }
        XCTAssertEqual(writing.wait(timeout: .now() + 10), .success)
        DispatchQueue.global().async { closing.signal(); fence.close(); closed.signal() }
        XCTAssertEqual(closing.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(closed.wait(timeout: .now() + 0.3), .timedOut, "Closing waits for the write under way")
        finish.signal()
        XCTAssertEqual(closed.wait(timeout: .now() + 10), .success)
        var wrote = false
        XCTAssertFalse(fence.write { wrote = true })
        XCTAssertFalse(wrote, "Nothing is written once closed")
    }

    /// A model catalog read once the runtime shut down isn't saved: the store's next owner
    /// may have saved a newer one.
    func testACatalogReadAfterShutdownIsNotSaved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-catalog-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try AgentRuntimeService(storageDirectory: root.appendingPathComponent("agents"), home: root,
                                              projectDirectory: { _ in root })
        service.shutdown()
        XCTAssertFalse(service.models.cacheWrites.write {}, "Shutdown closes the catalog's saving")
    }

    /// The service's discovery providers are the ones its conversations' reverts wait for.
    /// A host callback that shuts the service down while another shutdown already runs, and
    /// waits for that callback, returns at once, so neither waits for the other.
    func testAShutdownFromACallbackDuringAnotherShutdownReturns() async throws {
        let root = try root()
        let service = try AgentRuntimeService(storageDirectory: root.appendingPathComponent("agents"), home: root,
                                              projectDirectory: { _ in root })
        let admitted = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0), once = CompletionFlag()
        let fromCallback = DispatchSemaphore(value: 0), fromOutside = DispatchSemaphore(value: 0)
        service.shutdownAdmitted = { admitted.signal() }
        service.activityChanged = { _, _ in
            guard !once.isSet else { return }
            once.set()
            entered.signal()
            // Once the other shutdown runs, which waits for this callback.
            guard admitted.wait(timeout: .now() + 10) == .success else { return XCTFail("The other shutdown never ran") }
            service.shutdown()
            fromCallback.signal()
        }
        _ = try await service.handle(.create(session: SessionId(), project: ProjectId(), provider: .claude))
        XCTAssertEqual(entered.wait(timeout: .now() + 10), .success)
        DispatchQueue.global().async {
            service.shutdown()
            fromOutside.signal()
        }
        XCTAssertEqual(fromCallback.wait(timeout: .now() + 10), .success, "The callback's shutdown returned")
        XCTAssertEqual(fromOutside.wait(timeout: .now() + 10), .success, "The other shutdown finished")
    }

    /// A shutdown asked for while another runs returns once that one has finished, and one
    /// asked for later once the callbacks already queued have run.
    func testAShutdownDuringOrAfterAnotherWaitsForIt() async throws {
        let root = try root()
        let service = try AgentRuntimeService(storageDirectory: root.appendingPathComponent("agents"), home: root,
                                              projectDirectory: { _ in root })
        let armed = CompletionFlag(), held = DispatchSemaphore(value: 0), releaseCallback = DispatchSemaphore(value: 0)
        service.activityChanged = { _, _ in
            guard armed.isSet else { return }
            armed.clear()
            held.signal()
            releaseCallback.wait()
        }
        _ = try await service.handle(.create(session: SessionId(), project: ProjectId(), provider: .claude))
        let admitted = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        service.shutdownAdmitted = { admitted.signal(); release.wait() }
        let shutdowns = DispatchGroup(), second = CompletionFlag()
        // However the test ends, the held shutdown is let go and both are waited for.
        defer { release.signal(); XCTAssertEqual(shutdowns.wait(timeout: .now() + 10), .success) }
        DispatchQueue.global().async(group: shutdowns) { service.shutdown() }
        XCTAssertEqual(admitted.wait(timeout: .now() + 10), .success)
        DispatchQueue.global().async(group: shutdowns) { service.shutdown(); second.set() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(second.isSet, "Returned before the shutdown under way finished")
        release.signal()
        XCTAssertEqual(shutdowns.wait(timeout: .now() + 10), .success)
        // Later, it waits for a callback still running, as the first one did.
        armed.set()
        DispatchQueue.global().async { service.publishActivity() }
        XCTAssertEqual(held.wait(timeout: .now() + 10), .success)
        let third = CompletionFlag(), thirdDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { service.shutdown(); third.set(); thirdDone.signal() }
        defer { releaseCallback.signal(); XCTAssertEqual(thirdDone.wait(timeout: .now() + 10), .success) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(third.isSet, "Returned while a queued callback still ran")
    }

    func testRevertsWaitForTheServicesDiscoveryProviders() throws {
        let fixture = try AgentRuntimeFixture("""
        trap '' TERM
        exec sleep 30
        """)
        defer { fixture.remove() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-discovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try AgentRuntimeService(storageDirectory: root.appendingPathComponent("agents"), home: root,
                                              projectDirectory: { _ in root })
        defer { service.shutdown() }
        let folder = revertScope(fixture.directory.path)
        XCTAssertFalse(service.sessions.otherProvidersMayRun(folder))
        XCTAssertEqual(service.sessions.otherProviderProcesses(), [])
        let process = try service.discoveries.launch(.init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [fixture.script.path, fixture.log.path],
                                                           environment: AgentProcess.environment()),
                                                     directory: fixture.directory.path, onLine: { _ in }, onExit: { _, _ in })
        defer { process.stop() }
        XCTAssertTrue(service.sessions.otherProvidersMayRun(folder))
        XCTAssertTrue(service.sessions.otherProvidersMayRun(revertScope(fixture.directory.deletingLastPathComponent().path)), "And in a folder around its own")
        XCTAssertEqual(service.sessions.otherProviderProcesses(), [process.processIdentifier], "For a revert to find where it works now")
    }
}
