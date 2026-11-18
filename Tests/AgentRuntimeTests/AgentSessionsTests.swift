import AgentCore
import Foundation
import XCTest
@testable import AgentRuntime

private final class FakeAgentRuntime: AgentSessionRuntime, @unchecked Sendable {
    let callback: @Sendable (AgentRuntimeEvent) -> Void
    let lock = NSLock()
    var onSend: (@Sendable () async throws -> Void)?
    var onSteer: (@Sendable () async throws -> Void)?
    var onApprove: (@Sendable (String, Bool) async throws -> Void)?
    var onInterrupt: (@Sendable () async throws -> Void)?
    var onStop: (@Sendable () -> Void)?
    var onAccess: (@Sendable (AgentAccessMode) async throws -> Void)?
    private var exitingProcesses = false
    /// Whether a process it replaced still exits.
    var exiting: Bool {
        get { lock.withLock { exitingProcesses } }
        set { lock.withLock { exitingProcesses = newValue } }
    }
    private var launchedIn: AgentFolder?
    private var launchedProcesses: [Int32] = []
    private var refusedLaunches = false
    /// The folder its provider runs in, as a launched provider reports it.
    var folder: AgentFolder? {
        get { lock.withLock { launchedIn } }
        set { lock.withLock { launchedIn = newValue } }
    }
    /// Its provider's processes, as a launched provider reports them.
    var processes: [Int32] {
        get { lock.withLock { launchedProcesses } }
        set { lock.withLock { launchedProcesses = newValue } }
    }
    /// Whether it was told to launch nothing more.
    var launchesRefused: Bool { lock.withLock { refusedLaunches } }
    func mayRun(in scope: AgentRevertScope) -> Bool {
        folder.map { scope.holds($0) } == true || processes.contains(where: scope.processes.contains)
    }
    func isStopping(in scope: AgentRevertScope) -> Bool { exiting && mayRun(in: scope) }
    func providerProcesses() -> [Int32] { processes }
    func refuseLaunches() { lock.withLock { refusedLaunches = true } }
    /// Runs as a follow-up is about to be handed over, before Stop can no longer prevent it.
    var onSteerEntered: (@Sendable () async -> Void)?
    func steer(text: String, attachments: [StagedAgentAttachment], delivery: AgentDelivery) async throws {
        await onSteerEntered?()
        guard delivery.handOver() else { throw AgentFollowUpRefused() }
        try await steer(text: text, attachments: attachments)
    }
    private var stopCount = 0
    private var submittedModels: [String?] = []
    private var submittedEfforts: [AgentReasoningEffort?] = []
    private var currentAccess: AgentAccessMode = .standard
    var providerSession: String? = "provider-resume-id"
    private var prepared: [AgentLaunch] = []
    var launches: [AgentLaunch] { lock.withLock { prepared } }
    var stops: Int { lock.withLock { stopCount } }
    var models: [String?] { lock.withLock { submittedModels } }
    var efforts: [AgentReasoningEffort?] { lock.withLock { submittedEfforts } }
    var access: AgentAccessMode { lock.withLock { currentAccess } }

    init(_ callback: @escaping @Sendable (AgentRuntimeEvent) -> Void) { self.callback = callback }
    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?) async throws {
        lock.withLock { submittedModels.append(model); submittedEfforts.append(reasoningEffort) }
        if let providerSession { callback(.providerSession(providerSession)) }
        if let onSend { try await onSend() }
    }
    func steer(text: String, attachments: [StagedAgentAttachment]) async throws {
        guard let onSteer else { throw AgentRuntimeError("Unsupported") }
        try await onSteer()
    }
    func approve(request: String, allow: Bool) async throws {
        if let onApprove { try await onApprove(request, allow) } else { callback(.status(.idle)) }
    }
    private var allowedTools: Set<String> = []
    var alwaysAllowed: Set<String> { lock.withLock { allowedTools } }
    func approve(request: String, allow: Bool, always: Bool, reason: String?) async throws {
        try await approve(request: request, allow: allow)
    }
    func setAlwaysAllowed(_ tools: Set<String>) async throws { lock.withLock { allowedTools = tools } }
    func setAccess(_ mode: AgentAccessMode) async throws {
        lock.withLock { currentAccess = mode }
        if let onAccess { try await onAccess(mode) }
    }
    func interrupt() async throws {
        if let onInterrupt { try await onInterrupt() } else { callback(.status(.idle)) }
    }
    func stop() {
        lock.withLock { stopCount += 1 }
        onStop?()
    }
    func prepare(_ launch: AgentLaunch) {
        lock.withLock { prepared.append(launch) }
    }
}

private final class AgentRuntimeBox: @unchecked Sendable {
    let lock = NSLock()
    private var value: FakeAgentRuntime?
    var runtime: FakeAgentRuntime? { lock.withLock { value } }
    func install(_ runtime: FakeAgentRuntime) { lock.withLock { value = runtime } }
}

private final class AgentRuntimeResumes: @unchecked Sendable {
    let lock = NSLock()
    private var recorded: [String?] = []
    var values: [String?] { lock.withLock { recorded } }
    func append(_ value: String?) { lock.withLock { recorded.append(value) } }
}

private final class AgentDirectories: @unchecked Sendable {
    let lock = NSLock()
    private var list: [String] = []
    var values: [String] { lock.withLock { list } }
    func append(_ directory: String) { lock.withLock { list.append(directory) } }
}

private final class AgentEventCount: @unchecked Sendable {
    let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private actor AgentSubmissionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

final class AgentSessionsTests: XCTestCase {
    func testPlanSelectionPersistsAndRejectsMidTurnChanges() async throws {
        let root = try root()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in FakeAgentRuntime(callback) })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        let selected = try await sessions.handle(.setPlan(session: id, enabled: true))
        let decoded = try WireJSON.decode(AgentChatSnapshot.self, from: WireJSON.encode(selected))
        XCTAssertEqual(decoded.planMode, true)
        _ = try await sessions.handle(.setPlan(session: id, enabled: false))
        _ = try await sessions.handle(.send(session: id, text: "Start", model: nil))
        do {
            _ = try await sessions.handle(.setPlan(session: id, enabled: true))
            XCTFail("Must not change a running turn's mode")
        } catch {}
        let active = try await sessions.handle(.read(session: id))
        XCTAssertEqual(active.planMode, false)
    }

    func testActiveFollowupIsPersistedWithoutReplacingTurnOrRestartingRuntime() async throws {
        let root = try root()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSteer = {}
            return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        let first = try await sessions.handle(.send(session: id, text: "Start", model: nil))
        let next = try await sessions.handle(.send(session: id, text: "Focus on tests", model: nil))
        XCTAssertEqual(next.status, .working)
        XCTAssertEqual(next.items.filter { $0.kind == .user }.map(\.text), ["Start", "Focus on tests"])
        XCTAssertEqual(next.turns, first.turns)
        let read = try await sessions.handle(.read(session: id))
        XCTAssertEqual(read, next)
    }

    func testFollowupArrivingAsTheTurnEndsStartsANewTurn() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSteer = {
                callback(.status(.idle))
                throw AgentTurnFinishedError()
            }
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        let first = try await sessions.handle(.send(session: id, text: "Start", model: nil))
        XCTAssertEqual(first.status, .working)
        let next = try await sessions.handle(.send(session: id, text: "Late follow-up", model: nil))
        XCTAssertEqual(next.status, .working)
        XCTAssertEqual(next.items.filter { $0.kind == .user }.map(\.text), ["Start", "Late follow-up"])
        XCTAssertEqual(next.turns?.count, 2)
        XCTAssertEqual(box.runtime?.models.count, 2)
    }

    func testContextTelemetryPersistsAndModelChangesClearItWithoutChangingDefaultSelection() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = {
                callback(.resolvedModel("provider-default"))
                callback(.contextUsage(.init(usedTokens: 42_000, contextWindow: 200_000)))
                callback(.status(.idle))
            }
            box.install(runtime)
            return runtime
        })
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        let submitted = try await sessions.handle(.send(session: id, text: "hello", model: nil))
        XCTAssertEqual(submitted.contextUsage, .init(usedTokens: 42_000, contextWindow: 200_000))
        XCTAssertEqual(submitted.resolvedModel, "provider-default")
        XCTAssertNil(submitted.model, "Resolved telemetry must not change provider-default selection semantics")
        sessions.shutdown()

        let restored = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            // Deliberately do not emit new telemetry, to expose stale values.
            runtime.onSend = { callback(.status(.idle)) }
            box.install(runtime)
            return runtime
        })
        defer { restored.shutdown() }
        let recovered = try await restored.handle(.read(session: id))
        XCTAssertEqual(recovered.contextUsage, submitted.contextUsage)
        XCTAssertEqual(recovered.resolvedModel, "provider-default")
        let sameModel = try await restored.handle(.send(session: id, text: "again", model: nil, reasoningEffort: .high))
        XCTAssertEqual(sameModel.contextUsage, submitted.contextUsage, "Effort alone does not invalidate the context capacity")
        let changedModel = try await restored.handle(.send(session: id, text: "switch", model: "other"))
        XCTAssertNil(changedModel.contextUsage)
        XCTAssertNil(changedModel.resolvedModel)
    }

    func testProviderChangeClearsUnestablishedTelemetryAndFencesLateEvents() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { provider, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.providerSession = nil
            runtime.onSend = {
                if provider == .claude {
                    callback(.contextUsage(.init(usedTokens: 123)))
                    callback(.resolvedModel("claude-default"))
                    callback(.failure("startup failed"))
                } else { callback(.status(.idle)) }
            }
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        let failed = try await sessions.handle(.send(session: id, text: "hello", model: nil))
        XCTAssertEqual(failed.contextUsage?.usedTokens, 123)
        let old = try XCTUnwrap(box.runtime)
        let switched = try await sessions.handle(.send(session: id, text: "retry", model: nil, provider: .codex))
        XCTAssertNil(switched.contextUsage)
        XCTAssertNil(switched.resolvedModel)
        old.callback(.contextUsage(.init(usedTokens: 999)))
        let latest = try await sessions.handle(.read(session: id))
        XCTAssertNil(latest.contextUsage)
    }

    func testCheckpointsSeparateImmediateFollowupTurnsAndPersist() async throws {
        let storage = try root()
        let repo = try GitTestRepo(commit: false)
        try repo.write("file.txt", "before\n")
        try repo.commit("initial")
        let directory = repo.path
        let sends = AgentEventCount()
        let sessions = try AgentSessions(root: storage, projectDirectory: { _ in directory }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = {
                sends.increment()
                let text = sends.count == 1 ? "first\n" : "second\nextra\n"
                try text.write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8)
                callback(.status(.idle))
            }
            return runtime
        })
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.send(session: id, text: "first", model: nil))
        _ = try await sessions.handle(.send(session: id, text: "follow up immediately", model: nil))
        var snapshot = try await sessions.handle(.read(session: id))
        for _ in 0..<100 where snapshot.turns?.last?.checkpoint == nil {
            try await Task.sleep(for: .milliseconds(30))
            snapshot = try await sessions.handle(.read(session: id))
        }
        let turns = try XCTUnwrap(snapshot.turns)
        XCTAssertEqual(turns.count, 2)
        let first = try XCTUnwrap(turns[0].checkpoint)
        let second = try XCTUnwrap(turns[1].checkpoint)
        XCTAssertEqual(first.files.map(\.path), ["file.txt"])
        XCTAssertEqual(first.additions, 1)
        XCTAssertEqual(first.deletions, 1)
        XCTAssertEqual(second.additions, 2)
        XCTAssertEqual(second.deletions, 1)
        XCTAssertNotEqual(first.id, second.id)
        let historical = try await sessions.checkpoint(.init(session: id, checkpoint: first.id, path: "file.txt"))
        XCTAssertTrue(historical.diff?.rows.contains { $0.text == "+first" } == true)
        XCTAssertFalse(historical.diff?.rows.contains { $0.text == "+second" } == true,
                       "Opening a turn diff must not read the current worktree")
        do {
            _ = try await sessions.checkpoint(.init(session: SessionId(), checkpoint: first.id))
            XCTFail("A checkpoint is scoped to its owning conversation")
        } catch {}
        do {
            _ = try await sessions.checkpoint(.init(session: id, checkpoint: first.id, path: "../outside"))
            XCTFail("Only paths recorded in this checkpoint may be read")
        } catch {}

        for checkpoint in [first, second] {
            let recordURL = storage.appendingPathComponent("checkpoints/" + id.description + "/" + checkpoint.id + ".json")
            let record = try JSONDecoder().decode(AgentCheckpointRecord.self, from: Data(contentsOf: recordURL))
            XCTAssertEqual(record.files, checkpoint.files)
        }
        sessions.shutdown()
        let restored = try AgentSessions(root: storage, projectDirectory: { _ in directory })
        defer { restored.shutdown() }
        let saved = try await restored.handle(.read(session: id))
        XCTAssertEqual(saved.turns, turns)
    }

    func testRestartRecoversPersistedBaselineAndCompletedRecordBeforeTranscriptUpdate() async throws {
        for finalRecordExists in [false, true] {
            let storage = try root()
            let repo = try GitTestRepo(commit: false)
            try repo.write("file", "before\n")
            try repo.commit("initial")
            let store = AgentCheckpointStore()
            let before = try store.capture(directory: repo.path)
            try repo.write("file", "after\n")
            let id = SessionId(), userID = UUID().uuidString
            let folder = storage.appendingPathComponent("checkpoints/" + id.description)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(AgentCheckpointPending(turnID: userID, before: before))
                .write(to: folder.appendingPathComponent("pending-" + userID + ".json"))
            if finalRecordExists {
                let after = try store.capture(directory: repo.path)
                let record = AgentCheckpointRecord(before: before, after: after,
                    files: [.init(path: "file", additions: 1, deletions: 1)])
                try JSONEncoder().encode(record).write(to: folder.appendingPathComponent(userID + ".json"))
            }
            let started = Date(timeIntervalSince1970: 100)
            let snapshot = AgentChatSnapshot(session: id, project: ProjectId(), provider: .codex,
                turns: [.init(userItemID: userID, startedAt: started,
                    completedAt: finalRecordExists ? started.addingTimeInterval(2) : nil,
                    status: finalRecordExists ? .idle : .working)],
                status: finalRecordExists ? .idle : .working,
                items: [.init(id: userID, kind: .user, text: "Edit the file")])
            let snapshotJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
            let saved = try JSONSerialization.data(withJSONObject: ["snapshot": snapshotJSON, "directory": repo.path])
            try saved.write(to: storage.appendingPathComponent(id.description + ".json"))
            let directory = repo.path
            let sessions = try AgentSessions(root: storage, projectDirectory: { _ in directory })
            var recovered = try await sessions.handle(.read(session: id))
            for _ in 0..<100 where recovered.turns?.first?.checkpoint == nil {
                try await Task.sleep(for: .milliseconds(20))
                recovered = try await sessions.handle(.read(session: id))
            }
            let checkpoint = try XCTUnwrap(recovered.turns?.first?.checkpoint)
            XCTAssertEqual(checkpoint.id, userID)
            XCTAssertEqual(checkpoint.additions, 1)
            XCTAssertEqual(checkpoint.deletions, 1)
            let historical = try await sessions.checkpoint(.init(session: id, checkpoint: userID, path: "file"))
            XCTAssertTrue(historical.diff?.rows.contains { $0.text == "-before" } == true)
            sessions.shutdown()
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("pending-" + userID + ".json").path))
        }
    }

    func testStartupRetiresOrphanedCheckpointRecordsAndTheirPrivateRefs() async throws {
        let storage = try root()
        let repo = try GitTestRepo(commit: true)
        let store = AgentCheckpointStore()
        let before = try store.capture(directory: repo.path)
        let after = try store.capture(directory: repo.path)
        let id = SessionId(), oldTurn = UUID().uuidString
        let folder = storage.appendingPathComponent("checkpoints/" + id.description)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(AgentCheckpointRecord(before: before, after: after, files: []))
            .write(to: folder.appendingPathComponent(oldTurn + ".json"))
        try JSONEncoder().encode(AgentCheckpointPending(turnID: oldTurn, before: before))
            .write(to: folder.appendingPathComponent("pending-" + oldTurn + ".json"))
        let snapshot = AgentChatSnapshot(session: id, project: ProjectId(), provider: .codex)
        let snapshotJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
        try JSONSerialization.data(withJSONObject: ["snapshot": snapshotJSON, "directory": repo.path])
            .write(to: storage.appendingPathComponent(id.description + ".json"))
        let directory = repo.path
        let sessions = try AgentSessions(root: storage, projectDirectory: { _ in directory })
        sessions.shutdown()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        XCTAssertThrowsError(try repo.run("rev-parse", "--verify", before.reference))
        XCTAssertThrowsError(try repo.run("rev-parse", "--verify", after.reference))
        XCTAssertNoThrow(try repo.run("rev-parse", "--verify", "HEAD"))
    }



    /// Forking from an earlier message resumes the provider conversation at the message
    /// that turn began after; the runtime turns that into `--resume-session-at`, which
    /// `testClaudeForkForksOnlyUntilItsNewSessionIsKnown` checks against a Claude peer.
    func testForkFromAnEarlierMessageStartsFromBeforeIt() async throws {
        let root = try root(), box = AgentRuntimeBox(), messages = AgentEventCount()
        let factory: AgentSessions.Factory = { _, _, resume, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.providerSession = resume == nil ? "source-conversation" : "forked-conversation"
            runtime.onSend = {
                messages.increment()
                callback(.providerMessage("message-\(messages.count)"))
                callback(.item(AgentChatItem(id: "answer-\(messages.count)", kind: .assistant, text: "Answer \(messages.count)")))
                callback(.status(.idle))
            }
            box.install(runtime)
            return runtime
        }
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: factory)
        defer { sessions.shutdown() }
        let source = SessionId(), project = ProjectId()
        _ = try await sessions.handle(.create(session: source, project: project, provider: .claude))
        _ = try await sessions.handle(.send(session: source, text: "First", model: nil))
        _ = try await sessions.handle(.send(session: source, text: "Second", model: nil))
        _ = try await sessions.handle(.send(session: source, text: "Third", model: nil))
        let original = try await sessions.handle(.read(session: source))
        let second = try XCTUnwrap(original.items.first { $0.text == "Second" })
        let fork = SessionId()
        guard case .forked(let copied) = try await sessions.conversation(.fork(session: fork, from: source, project: nil, at: second.id)) else {
            return XCTFail("Unexpected reply")
        }
        XCTAssertEqual(copied.items.map(\.text), ["First", "Answer 1"], "The fork holds what came before that message")
        XCTAssertEqual(copied.status, .idle)
        guard case .forked(let again) = try await sessions.conversation(.fork(session: fork, from: source, project: nil, at: second.id)) else {
            return XCTFail("Unexpected reply")
        }
        XCTAssertEqual(again, copied, "Idempotent")
        _ = try await sessions.handle(.send(session: fork, text: "Second, differently", model: nil))
        XCTAssertEqual(box.runtime?.launches.first?.forkSource, "source-conversation")
        XCTAssertEqual(box.runtime?.launches.first?.forkPoint, "message-1", "It resumes after the first turn's last message")

        let first = try XCTUnwrap(original.items.first { $0.text == "First" })
        let fresh = SessionId()
        guard case .forked(let empty) = try await sessions.conversation(.fork(session: fresh, from: source, project: nil, at: first.id)) else {
            return XCTFail("Unexpected reply")
        }
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertNil(empty.providerSession, "Forking at the first message is a new conversation")

        let codex = SessionId()
        _ = try await sessions.handle(.create(session: codex, project: project, provider: .codex))
        _ = try await sessions.handle(.send(session: codex, text: "Hi", model: nil))
        let codexSnapshot = try await sessions.handle(.read(session: codex))
        let hi = try XCTUnwrap(codexSnapshot.items.first { $0.kind == .user })
        do {
            _ = try await sessions.conversation(.fork(session: SessionId(), from: codex, project: nil, at: hi.id))
            XCTFail("Codex forks only whole threads")
        } catch {}
    }

    func testImportedConversationResumesItsProviderSessionAndIsImportedOnce() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let resumed = AgentRuntimeResumes()
        let factory: AgentSessions.Factory = { _, _, resume, callback in
            resumed.append(resume)
            let runtime = FakeAgentRuntime(callback)
            runtime.providerSession = resume
            runtime.onSend = { callback(.status(.idle)) }
            box.install(runtime)
            return runtime
        }
        var sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: factory)
        let pane = SessionId(), other = SessionId(), project = ProjectId()
        let saved = AgentHistoryTranscript(items: [
            AgentChatItem(id: "u1", kind: .user, text: "Fix the login bug", isComplete: false),
            AgentChatItem(id: "a1", kind: .assistant, text: "Fixed it."),
        ], resolvedModel: "claude-opus-5-5")
        let directories = AgentRuntimeResumes()
        let transcript: @Sendable (String) throws -> AgentHistoryTranscript = { directory in
            directories.append(directory)
            return saved
        }
        let request = AgentHistoryImport(session: pane, project: project, provider: .codex, providerSession: "thread-1")

        // An unused pane takes the conversation over, whatever provider it started with.
        _ = try await sessions.handle(.create(session: pane, project: project, provider: .claude))
        _ = try await sessions.handle(.setAccess(session: pane, mode: .ask))
        let imported = try await sessions.importHistory(request, transcript: transcript)
        XCTAssertEqual(imported.session, pane)
        XCTAssertEqual(imported.provider, .codex)
        XCTAssertEqual(imported.providerSession, "thread-1")
        XCTAssertEqual(imported.accessMode, .ask)
        XCTAssertEqual(imported.status, .idle)
        XCTAssertEqual(imported.items.prefix(2).map(\.text), ["Fix the login bug", "Fixed it."])
        XCTAssertTrue(imported.items.allSatisfy(\.isComplete))
        XCTAssertEqual(imported.items.last?.kind, .notice)
        XCTAssertEqual(directories.values, [root.path])
        XCTAssertNoThrow(try imported.validate())
        XCTAssertEqual(sessions.openProviderSessions(), ["thread-1"])

        // Importing it again shows the conversation that already continues it.
        let again = try await sessions.importHistory(
            AgentHistoryImport(session: other, project: project, provider: .codex, providerSession: "thread-1"),
            transcript: transcript)
        XCTAssertEqual(again.session, pane)
        // A conversation in use can't be replaced.
        do {
            _ = try await sessions.importHistory(
                AgentHistoryImport(session: pane, project: project, provider: .claude, providerSession: "other"),
                transcript: transcript)
            XCTFail("An established conversation was replaced")
        } catch {}

        // It survives a restart, and the next message resumes the provider's conversation.
        sessions.shutdown()
        sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: factory)
        defer { sessions.shutdown() }
        let continued = try await sessions.handle(.send(session: pane, text: "Thanks", model: nil))
        XCTAssertEqual(resumed.values, ["thread-1"])
        XCTAssertNil(box.runtime?.launches.first?.forkSource)
        XCTAssertEqual(continued.providerSession, "thread-1")
        XCTAssertEqual(continued.items.filter { $0.kind == .user }.map(\.text), ["Fix the login bug", "Thanks"])
    }

    func testForkIntoAnotherProjectWorksInItsFolder() async throws {
        let root = try root(), box = AgentRuntimeBox(), directories = AgentDirectories()
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let source = SessionId(), fork = SessionId(), project = ProjectId(), branch = ProjectId()
        let factory: AgentSessions.Factory = { _, directory, resume, callback in
            directories.append(directory)
            let runtime = FakeAgentRuntime(callback)
            runtime.providerSession = resume == nil ? "source-conversation" : "forked-conversation"
            runtime.onSend = { callback(.status(.idle)) }
            box.install(runtime)
            return runtime
        }
        let sessions = try AgentSessions(root: root, projectDirectory: { $0 == branch ? worktree.path : root.path },
                                         factory: factory)
        defer { sessions.shutdown() }
        _ = try await sessions.handle(.create(session: source, project: project, provider: .claude))
        _ = try await sessions.handle(.send(session: source, text: "Plan both fixes", model: nil))

        let copied = try await sessions.handle(.fork(session: fork, from: source, project: branch))
        XCTAssertEqual(copied.project, branch)
        XCTAssertEqual(copied.items.filter { $0.kind == .user }.map(\.text), ["Plan both fixes"])
        let again = try await sessions.handle(.fork(session: fork, from: source, project: branch))
        XCTAssertEqual(again, copied)
        do {
            _ = try await sessions.handle(.fork(session: fork, from: source))
            XCTFail("A fork's ID can't be reused for a fork in another project")
        } catch {}

        _ = try await sessions.handle(.send(session: fork, text: "Try the first", model: nil))
        XCTAssertEqual(directories.values, [root.path, worktree.path])
        XCTAssertEqual(box.runtime?.launches.first?.forkSource, "source-conversation")
    }

    private func root() throws -> URL {

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testIdempotentCreateSubmissionSnapshotAndResumeAfterRestart() async throws {
        let root = try root()
        let box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            box.install(runtime)
            return runtime
        })
        let id = SessionId(), project = ProjectId()
        let create = AgentChatRequest.create(session: id, project: project, provider: .claude)
        let initial = try await sessions.handle(create)
        XCTAssertNil(box.runtime, "Create must not launch a provider")
        let duplicate = try await sessions.handle(create)
        XCTAssertEqual(initial, duplicate)
        let submitted = try await sessions.handle(.send(session: id, text: "hello", model: "chosen", reasoningEffort: .high))
        XCTAssertEqual(submitted.status, .working)
        XCTAssertEqual(submitted.providerSession, "provider-resume-id")
        XCTAssertEqual(submitted.items.map(\.text), ["hello"])
        do {
            _ = try await sessions.handle(.send(session: id, text: "duplicate", model: nil))
            XCTFail("Concurrent turns must be refused")
        } catch {}
        sessions.shutdown()
        let resumed = AgentRuntimeBox()
        let restored = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, resume, callback in
            XCTAssertEqual(resume, "provider-resume-id")
            let runtime = FakeAgentRuntime(callback)
            resumed.install(runtime)
            return runtime
        })
        defer { restored.shutdown() }
        let recovered = try await restored.handle(.read(session: id))
        XCTAssertEqual(recovered.status, .failed)
        XCTAssertEqual(recovered.reasoningEffort, .high)
        XCTAssertEqual(recovered.model, "chosen")
        XCTAssertTrue(recovered.items.contains { $0.kind == .notice && $0.text.contains("interrupted") })
        XCTAssertNil(resumed.runtime, "Recovery is read-only until the next send")
        let reset = try await restored.handle(.send(session: id, text: "resume", model: nil))
        XCTAssertNil(reset.model)
        XCTAssertNil(reset.reasoningEffort)
        XCTAssertNotNil(resumed.runtime)
    }

    func testSynchronousCompletionIsNotOverwrittenBySendAndLateCallbacksCannotReopenClosedSession() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = { callback(.status(.idle)) }
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        let submitted = try await sessions.handle(.send(session: id, text: "hello", model: nil))
        XCTAssertEqual(submitted.status, .idle)
        XCTAssertTrue(sessions.hasSessions, "An idle provider process must still keep the server busy")
        let closed = try await sessions.handle(.close(session: id))
        box.runtime?.callback(.status(.working))
        box.runtime?.callback(.textDelta(id: "late", text: "must be ignored"))
        let read = try await sessions.handle(.read(session: id))
        XCTAssertEqual(read, closed)
        XCTAssertFalse(sessions.hasSessions)
    }

    func testOutputIsBoundedAndBurstEventsAreCoalesced() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let notified = expectation(description: "coalesced revision")
        notified.assertForOverFulfill = false
        let events = AgentEventCount()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, changed: { _, _ in
            events.increment()
            notified.fulfill()
        }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = {
                for _ in 0..<100 { callback(.textDelta(id: "answer", text: String(repeating: "🙂", count: 1000))) }
            }
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        let snapshot = try await sessions.handle(.send(session: id, text: "hello", model: nil))
        try snapshot.validate()
        XCTAssertLessThanOrEqual(snapshot.items.last?.text.utf8.count ?? 0, 64 * 1024)
        XCTAssertTrue(snapshot.items.last?.text.hasPrefix("[Earlier text truncated]") == true)
        XCTAssertFalse(snapshot.items.last?.text.contains("�") == true)
        XCTAssertGreaterThan(snapshot.revision, 100)
        await fulfillment(of: [notified], timeout: 2)
        XCTAssertLessThan(events.count, 20, "A burst must not emit an event per token")
    }

    func testCrashRecoveryMarksActiveCheckpointInterruptedWithoutLaunching() async throws {
        struct Checkpoint: Encodable {
            var snapshot: AgentChatSnapshot
            var directory: String
        }
        let root = try root(), session = SessionId()
        let user = AgentChatItem(kind: .user, text: "request before crash")
        let snapshot = AgentChatSnapshot(session: session, project: ProjectId(), provider: .claude,
                                         providerSession: "resume",
                                         turns: [.init(userItemID: user.id, startedAt: Date(timeIntervalSinceNow: -10))],
                                         status: .working, revision: 9,
                                         items: [user, AgentChatItem(kind: .assistant, text: "partial", isComplete: false)])
        try JSONEncoder().encode(Checkpoint(snapshot: snapshot, directory: root.path))
            .write(to: root.appendingPathComponent(session.description + ".json"))
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            XCTFail("Recovery must never launch a provider")
            return FakeAgentRuntime(callback)
        })
        defer { sessions.shutdown() }
        let read = try await sessions.handle(.read(session: session))
        XCTAssertEqual(read.status, .failed)
        XCTAssertEqual(read.providerSession, "resume")
        XCTAssertGreaterThan(read.revision, snapshot.revision)
        XCTAssertTrue(read.items.allSatisfy(\.isComplete))
        XCTAssertEqual(read.turns?.last?.status, .failed)
        XCTAssertEqual(read.turns?.last?.outcome, .interrupted)
        XCTAssertNotNil(read.turns?.last?.completedAt)
    }

    func testCloseWinsAgainstInFlightSubmissionAndProjectRemovalClosesAgents() async throws {
        let root = try root()
        let started = expectation(description: "submission started")
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = {
                started.fulfill()
                try await Task.sleep(nanoseconds: 150_000_000)
                callback(.status(.working))
            }
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId(), project = ProjectId()
        _ = try await sessions.handle(.create(session: session, project: project, provider: .codex))
        let sending = Task { try await sessions.handle(.send(session: session, text: "hello", model: nil)) }
        await fulfillment(of: [started], timeout: 2)
        sessions.close(project: project)
        let closed = try await sessions.handle(.read(session: session))
        XCTAssertEqual(closed.status, .closed)
        let submitted = try await sending.value
        XCTAssertEqual(submitted.status, .closed)
        XCTAssertEqual(submitted, closed)
    }

    func testPendingApprovalsSurviveTrimmingAndEscapedSnapshotFitsFrame() async throws {
        let root = try root()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = {
                callback(.item(AgentChatItem(id: "permission", kind: .approval,
                                            text: String(repeating: "Command ", count: 1000),
                                            detail: String(repeating: "🙂\0", count: 10000), isComplete: false)))
                for index in 0..<520 {
                    callback(.item(AgentChatItem(id: "tool-\(index)", kind: .tool,
                                                text: String(repeating: "\0", count: 2000))))
                }
                callback(.status(.waiting))
            }
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        let waiting = try await sessions.handle(.send(session: session, text: "hello", model: nil))
        XCTAssertTrue(waiting.items.contains { $0.id == "permission" && !$0.isComplete })
        let permission = try XCTUnwrap(waiting.items.first { $0.id == "permission" })
        XCTAssertTrue(permission.text.hasPrefix("[Earlier text truncated]"))
        XCTAssertTrue(permission.detail?.hasPrefix("[Earlier text truncated]") == true)
        XCTAssertFalse(permission.detail?.contains("�") == true)
        try waiting.validate()
        let frame = try WireJSON.encode(waiting)
        XCTAssertLessThan(frame.count, AgentLimits.maxFrame)
        let approved = try await sessions.handle(.approve(session: session, request: "permission", allow: true))
        XCTAssertEqual(approved.status, .idle)
    }

    func testServerSubmissionDeadlineStopsGenerationBeforeClientBudget() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, submissionTimeout: 0.02,
                                         factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = {
                try await Task.sleep(nanoseconds: 100_000_000)
                callback(.status(.working))
            }
            box.install(runtime)
            return runtime
        })
        // Only the provider's callbacks are followed here; a checkpoint's outcome would change the conversation later.
        sessions.capturesCheckpoints = false
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        let failed = try await sessions.handle(.send(session: session, text: "hello", model: nil))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(failed.items.contains { $0.text.contains("timed out") })
        try await Task.sleep(nanoseconds: 150_000_000)
        let read = try await sessions.handle(.read(session: session))
        XCTAssertEqual(read, failed, "Late callbacks must not revive a timed-out runtime")
        // The provider stops off the sessions queue, soon after.
        for _ in 0..<500 where box.runtime?.stops != 1 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(box.runtime?.stops, 1)
    }

    func testFailureRetryUsesNewRuntimeAndIgnoresOldGeneration() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: session, text: "first", model: "invalid-model"))
        let old = try XCTUnwrap(box.runtime)
        old.callback(.failure("disconnected"))
        let failed = try await sessions.handle(.read(session: session))
        XCTAssertEqual(failed.status, .failed)
        let retried = try await sessions.handle(.send(session: session, text: "retry", model: nil))
        XCTAssertFalse(old === box.runtime)
        XCTAssertEqual(retried.status, .working)
        XCTAssertNil(retried.model, "nil explicitly resets a failed model choice to the provider default")
        let replacement = try XCTUnwrap(box.runtime)
        XCTAssertEqual(replacement.models.count, 1)
        XCTAssertEqual(replacement.models, [nil])
        old.callback(.status(.idle))
        old.callback(.providerSession("stale"))
        let read = try await sessions.handle(.read(session: session))
        XCTAssertEqual(read, retried)
    }

    func testApprovingOneOfSeveralPermissionsKeepsRemainingApprovalWaiting() async throws {
        let root = try root()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = {
                for id in ["first", "second"] {
                    callback(.item(AgentChatItem(id: id, kind: .approval, text: "Allow?", isComplete: false)))
                }
                callback(.status(.waiting))
            }
            runtime.onApprove = { id, _ in
                callback(.item(AgentChatItem(id: id, kind: .approval, text: "Approved")))
                callback(.status(id == "first" ? .waiting : .idle))
            }
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.send(session: session, text: "hello", model: nil))
        let waiting = try await sessions.handle(.approve(session: session, request: "first", allow: true))
        XCTAssertEqual(waiting.status, .waiting)
        XCTAssertTrue(waiting.items.contains { $0.id == "second" && !$0.isComplete })
        let approved = try await sessions.handle(.approve(session: session, request: "second", allow: false))
        XCTAssertEqual(approved.status, .idle)
    }

    func testInterruptAcknowledgmentWaitsForAuthoritativeCompletionAndKeepsRuntimeReusable() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onInterrupt = {} // Acknowledged, but the provider has not finished the turn.
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.send(session: session, text: "hello", model: nil))
        let runtime = try XCTUnwrap(box.runtime)
        let acknowledged = try await sessions.handle(.interrupt(session: session))
        XCTAssertEqual(acknowledged.status, .working)
        XCTAssertEqual(runtime.stops, 0)
        runtime.callback(.status(.idle))
        let completed = try await sessions.handle(.read(session: session))
        XCTAssertEqual(completed.status, .idle)
        XCTAssertTrue(completed.items.contains { $0.kind == .notice && $0.text == "Agent interrupted." })
        XCTAssertEqual(completed.turns?.last?.outcome, .interrupted, "The reusable idle state must retain an observed user stop")
        XCTAssertEqual(runtime.stops, 0)
        let next = try await sessions.handle(.send(session: session, text: "next turn", model: nil))
        XCTAssertEqual(next.status, .working)
        XCTAssertTrue(runtime === box.runtime)
    }

    func testUnresponsiveInterruptIsStoppedOnlyAfterBoundedCompletionTimeout() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, interruptTimeout: 0.02,
                                         factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onInterrupt = {}
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: session, text: "hello", model: nil))
        let acknowledged = try await sessions.handle(.interrupt(session: session))
        XCTAssertEqual(acknowledged.status, .working)
        XCTAssertEqual(box.runtime?.stops, 0)
        try await Task.sleep(nanoseconds: 100_000_000)
        let stopped = try await sessions.handle(.read(session: session))
        XCTAssertEqual(stopped.status, .idle, "A stop the provider ignores still ends as a stop, not a failure")
        XCTAssertEqual(stopped.turns?.last?.outcome, .interrupted)
        XCTAssertTrue(stopped.items.contains { $0.kind == .notice && $0.text == "Agent interrupted." })
        // The provider stops off the sessions queue, soon after.
        for _ in 0..<500 where box.runtime?.stops != 1 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(box.runtime?.stops, 1)
        let resumed = try await sessions.handle(.send(session: session, text: "carry on", model: nil))
        XCTAssertEqual(resumed.status, .working)
    }

    /// A stopped or failed turn used to leave its unfinished tools `running` forever.
    func testToolsStillRunningWhenATurnEndsEarlyBecomeInterrupted() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, interruptTimeout: 0.02,
                                         factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onInterrupt = {}
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: session, text: "build", model: nil))
        let running = AgentChatItem(id: "bash", kind: .tool, text: "Bash", isComplete: false,
                                    tool: AgentToolActivity(name: "Bash", category: .command, status: .running))
        let finished = AgentChatItem(id: "read", kind: .tool, text: "Read", isComplete: true,
                                     tool: AgentToolActivity(name: "Read", category: .read, status: .completed))
        box.runtime?.callback(.item(running))
        box.runtime?.callback(.item(finished))
        _ = try await sessions.handle(.interrupt(session: session))
        try await Task.sleep(nanoseconds: 100_000_000)
        let stopped = try await sessions.handle(.read(session: session))
        XCTAssertEqual(stopped.items.first { $0.id == "bash" }?.tool?.status, .interrupted)
        XCTAssertEqual(stopped.items.first { $0.id == "read" }?.tool?.status, .completed)
        XCTAssertTrue(stopped.items.allSatisfy(\.isComplete))

        _ = try await sessions.handle(.send(session: session, text: "again", model: nil))
        box.runtime?.callback(.item(AgentChatItem(id: "bash-2", kind: .tool, text: "Bash", isComplete: false,
                                                  tool: AgentToolActivity(name: "Bash", category: .command, status: .running))))
        box.runtime?.callback(.failure("Provider crashed"))
        try await Task.sleep(nanoseconds: 50_000_000)
        let failed = try await sessions.handle(.read(session: session))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.items.first { $0.id == "bash-2" }?.tool?.status, .interrupted)
    }

    /// A stop the provider refused used to leave the turn working forever.
    func testAFailedInterruptEndsTheTurnByStoppingTheProvider() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onInterrupt = { throw AgentRuntimeError("broken pipe") }
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: session, text: "hello", model: nil))
        let stopped = try await sessions.handle(.interrupt(session: session))
        XCTAssertEqual(stopped.status, .idle)
        XCTAssertEqual(stopped.turns?.last?.outcome, .interrupted)
        XCTAssertTrue(stopped.items.contains { $0.text.contains("didn't take the stop") })
        // The provider stops off the sessions queue, soon after.
        for _ in 0..<500 where box.runtime?.stops != 1 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(box.runtime?.stops, 1)
        XCTAssertEqual(stopped.queuePaused, true, "Stop still holds the queue")
    }

    func testInterruptDuringStartupSettlesSendImmediatelyAndFencesLateCallbacks() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let gate = AgentSubmissionGate()
        let started = expectation(description: "startup blocked")
        let settled = expectation(description: "pending send settled without waiting for runtime")
        let stopped = expectation(description: "startup runtime stopped")
        let lateCallbacks = expectation(description: "old runtime callbacks delivered")
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let first = box.runtime == nil
            let runtime = FakeAgentRuntime(callback)
            if first {
                runtime.onSend = {
                    started.fulfill()
                    await gate.wait() // Deliberately ignores task cancellation.
                    callback(.providerSession("stale-startup-session"))
                    callback(.status(.working))
                    callback(.item(AgentChatItem(id: "stale", kind: .assistant, text: "must be ignored")))
                    lateCallbacks.fulfill()
                }
                runtime.onInterrupt = { XCTFail("A startup without a turn must be stopped, not gracefully interrupted") }
                runtime.onStop = { stopped.fulfill() }
            }
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .codex))
        let sending = Task {
            let snapshot = try await sessions.handle(.send(session: session, text: "hello", model: nil))
            settled.fulfill()
            return snapshot
        }
        await fulfillment(of: [started], timeout: 2)
        let interrupted = try await sessions.handle(.interrupt(session: session))
        XCTAssertEqual(interrupted.status, .idle)
        XCTAssertTrue(interrupted.items.contains { $0.kind == .notice && $0.text == "Agent interrupted." })
        await fulfillment(of: [settled, stopped], timeout: 1)
        let submission = try await sending.value
        XCTAssertEqual(submission, interrupted)
        let restarted = try await sessions.handle(.send(session: session, text: "retry", model: nil))
        XCTAssertEqual(restarted.status, .working)
        await gate.release()
        await fulfillment(of: [lateCallbacks], timeout: 2)
        let read = try await sessions.handle(.read(session: session))
        XCTAssertEqual(read, restarted, "Neither cancelled completion nor provider callbacks may mutate the replacement generation")
    }







    func testFailedFirstAttemptCanSwitchProviderAndOriginalCreateSeedReconnectsToSelectedProvider() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { provider, _, resume, callback in
            XCTAssertNil(resume)
            let runtime = FakeAgentRuntime(callback)
            if provider == .claude {
                runtime.providerSession = nil
                runtime.onSend = { throw AgentRuntimeError("CLI unavailable") }
            }
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId(), project = ProjectId()
        let seed = AgentChatRequest.create(session: session, project: project, provider: .claude)
        _ = try await sessions.handle(seed)
        let failed = try await sessions.handle(.send(session: session, text: "first attempt", model: nil))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertNil(failed.providerSession)
        XCTAssertTrue(failed.items.contains { $0.kind == .user })
        let selected = try await sessions.handle(.send(session: session, text: "retry with Codex", model: "gpt-6.1-sol",
                                                       reasoningEffort: .xhigh, provider: .codex))
        XCTAssertEqual(selected.provider, .codex)
        XCTAssertEqual(selected.status, .working)
        XCTAssertEqual(selected.model, "gpt-6.1-sol")
        XCTAssertEqual(selected.reasoningEffort, .xhigh)
        XCTAssertEqual(box.runtime?.efforts, [.xhigh])
        let reconnected = try await sessions.handle(seed)
        XCTAssertEqual(reconnected, selected, "The persisted pane's seed cannot overwrite the authoritative provider")
        do {
            _ = try await sessions.handle(.send(session: session, text: "busy switch", model: nil, provider: .claude))
            XCTFail("A busy provider cannot switch")
        } catch {}
        let unchanged = try await sessions.handle(.read(session: session))
        XCTAssertEqual(unchanged, selected)
        box.runtime?.callback(.status(.idle))
        let established = try await sessions.handle(.read(session: session))
        do {
            _ = try await sessions.handle(.send(session: session, text: "lose context", model: nil, provider: .claude))
            XCTFail("An established provider session cannot switch")
        } catch {}
        let afterRejection = try await sessions.handle(.read(session: session))
        XCTAssertEqual(afterRejection, established)
    }

    func testUnsupportedEffortAndBusyConfigurationChangesLeaveSnapshotUntouched() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        let original = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        do {
            _ = try await sessions.handle(.send(session: session, text: "unsupported", model: "claude-haiku-4-5",
                                               reasoningEffort: .init(rawValue: "bad\nvalue")))
            XCTFail("Control characters are not valid effort values")
        } catch {}
        do {
            _ = try await sessions.handle(.send(session: session, text: "invalid effort", model: "claude-opus-5-5",
                                               reasoningEffort: .init(rawValue: ""), provider: .claude))
            XCTFail("Validate effort before changing providers")
        } catch {}
        XCTAssertNil(box.runtime)
        let untouched = try await sessions.handle(.read(session: session))
        XCTAssertEqual(untouched, original)
        let working = try await sessions.handle(.send(session: session, text: "valid", model: "claude-opus-5-5",
                                                      reasoningEffort: .low))
        do {
            _ = try await sessions.handle(.send(session: session, text: "change while busy", model: nil,
                                               reasoningEffort: .medium))
            XCTFail("Cannot change an active turn's selection")
        } catch {}
        let afterBusy = try await sessions.handle(.read(session: session))
        XCTAssertEqual(afterBusy, working)
    }

    func testClaudeSelectionChangeRestartsWithResumeAndNilClearsBothOverrides() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { provider, _, resume, callback in
            XCTAssertEqual(provider, .claude)
            if box.runtime != nil { XCTAssertEqual(resume, "provider-resume-id") }
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = { callback(.status(.idle)) }
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: session, text: "one", model: "claude-opus-5-5", reasoningEffort: .low))
        let old = try XCTUnwrap(box.runtime)
        let selected = try await sessions.handle(.send(session: session, text: "two", model: "claude-opus-5-5", reasoningEffort: .max))
        XCTAssertEqual(selected.providerSession, "provider-resume-id")
        XCTAssertEqual(selected.reasoningEffort, .max)
        XCTAssertFalse(old === box.runtime)
        old.callback(.providerSession("stale"))
        let reset = try await sessions.handle(.send(session: session, text: "default", model: nil, reasoningEffort: nil))
        XCTAssertNil(reset.model)
        XCTAssertNil(reset.reasoningEffort)
        XCTAssertEqual(reset.providerSession, "provider-resume-id")
        XCTAssertEqual(box.runtime?.models, [nil])
        XCTAssertEqual(box.runtime?.efforts, [nil])
    }

    func testSuccessfulTurnWithoutProviderIDCannotSwitchEvenAfterRestart() async throws {
        let root = try root()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.providerSession = nil
            runtime.onSend = { callback(.status(.idle)) }
            return runtime
        })
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: session, text: "completed without output", model: nil))
        sessions.shutdown()
        let recovered = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            XCTFail("A rejected provider switch must not launch a process")
            return FakeAgentRuntime(callback)
        })
        defer { recovered.shutdown() }
        let before = try await recovered.handle(.read(session: session))
        XCTAssertNil(before.providerSession)
        do {
            _ = try await recovered.handle(.send(session: session, text: "switch", model: nil, provider: .codex))
            XCTFail("Successful-turn history must survive bounded transcript persistence")
        } catch {}
        let after = try await recovered.handle(.read(session: session))
        XCTAssertEqual(after, before)
    }

    func testAccessChangesApplyToPendingApprovalsPersistAndConfigureReplacementRuntime() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = {
                callback(.item(AgentChatItem(id: "search", kind: .approval, text: "WebSearch", isComplete: false)))
                callback(.item(AgentChatItem(id: "command", kind: .approval, text: "Bash", isComplete: false)))
                callback(.status(.waiting))
            }
            runtime.onAccess = { mode in
                if mode == .standard {
                    callback(.item(AgentChatItem(id: "search", kind: .approval, text: "Automatically approved")))
                    callback(.status(.waiting))
                } else if mode == .fullAccess {
                    callback(.item(AgentChatItem(id: "search", kind: .approval, text: "Automatically approved")))
                    callback(.item(AgentChatItem(id: "command", kind: .approval, text: "Automatically approved")))
                    callback(.status(.working))
                }
            }
            box.install(runtime)
            return runtime
        })
        let session = SessionId(), project = ProjectId()
        let initial = try await sessions.handle(.create(session: session, project: project, provider: .claude))
        XCTAssertEqual(initial.accessMode, .fullAccess)
        let ask = try await sessions.handle(.setAccess(session: session, mode: .ask))
        XCTAssertEqual(ask.accessMode, .ask)
        XCTAssertNil(box.runtime, "Changing access before the first send must not launch a provider")
        let waiting = try await sessions.handle(.send(session: session, text: "search then run", model: nil))
        XCTAssertEqual(waiting.status, .waiting)
        XCTAssertEqual(box.runtime?.access, .ask)
        let runtime = try XCTUnwrap(box.runtime)
        let standard = try await sessions.handle(.setAccess(session: session, mode: .standard))
        XCTAssertEqual(standard.accessMode, .standard)
        XCTAssertEqual(standard.status, .waiting)
        XCTAssertTrue(standard.items.contains { $0.id == "search" && $0.isComplete })
        XCTAssertTrue(standard.items.contains { $0.id == "command" && !$0.isComplete })
        XCTAssertTrue(runtime === box.runtime)
        let full = try await sessions.handle(.setAccess(session: session, mode: .fullAccess))
        XCTAssertEqual(full.status, .working)
        XCTAssertEqual(full.accessMode, .fullAccess)
        XCTAssertTrue(full.items.filter { $0.kind == .approval }.allSatisfy(\.isComplete))
        XCTAssertEqual(runtime.stops, 0, "Changing pending approvals must not restart the active turn")
        let refreshed = try await sessions.handle(.create(session: session, project: project, provider: .claude))
        XCTAssertEqual(refreshed, full)
        sessions.shutdown()

        let replacement = AgentRuntimeBox()
        let restored = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, resume, callback in
            XCTAssertEqual(resume, "provider-resume-id")
            let runtime = FakeAgentRuntime(callback)
            replacement.install(runtime)
            return runtime
        })
        defer { restored.shutdown() }
        let persisted = try await restored.handle(.read(session: session))
        XCTAssertEqual(persisted.accessMode, .fullAccess)
        _ = try await restored.handle(.send(session: session, text: "continue", model: nil))
        XCTAssertEqual(replacement.runtime?.access, .fullAccess, "Persisted explicit access must be installed before send")
    }

    func testAccessCompletionCannotMutateClosedGeneration() async throws {
        let root = try root()
        let gate = AgentSubmissionGate()
        let entered = expectation(description: "access update in flight")
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onAccess = { mode in
                guard mode == .fullAccess else { return }
                entered.fulfill()
                await gate.wait()
                callback(.item(AgentChatItem(id: "late", kind: .approval, text: "Automatically approved")))
                callback(.status(.working))
            }
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.setAccess(session: session, mode: .standard))
        _ = try await sessions.handle(.send(session: session, text: "start", model: nil))
        let changing = Task { try await sessions.handle(.setAccess(session: session, mode: .fullAccess)) }
        await fulfillment(of: [entered], timeout: 2)
        let closed = try await sessions.handle(.close(session: session))
        await gate.release()
        let returned = try await changing.value
        XCTAssertEqual(returned, closed)
        let read = try await sessions.handle(.read(session: session))
        XCTAssertEqual(read, closed)
        XCTAssertFalse(read.items.contains { $0.id == "late" })
    }

    func testTurnsRecordRealAcceptanceCompletionAndDoNotRewriteCompletedHistory() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        let before = Date()
        let sent = try await sessions.handle(.send(session: session, text: "first turn", model: nil))
        let turn = try XCTUnwrap(sent.turns?.first)
        XCTAssertEqual(turn.userItemID, sent.items.first { $0.kind == .user }?.id)
        XCTAssertGreaterThanOrEqual(turn.startedAt, before)
        XCTAssertLessThanOrEqual(turn.startedAt, Date())
        XCTAssertEqual(turn.status, .working)
        XCTAssertNil(turn.completedAt)
        box.runtime?.callback(.status(.waiting))
        let waiting = try await sessions.handle(.read(session: session))
        XCTAssertEqual(waiting.turns?.first?.status, .waiting)
        XCTAssertEqual(waiting.turns?.first?.startedAt, turn.startedAt)
        box.runtime?.callback(.status(.idle))
        let completed = try await sessions.handle(.read(session: session))
        let finished = try XCTUnwrap(completed.turns?.first)
        let end = try XCTUnwrap(finished.completedAt)
        XCTAssertGreaterThanOrEqual(end, finished.startedAt)
        XCTAssertEqual(finished.status, .idle)
        XCTAssertEqual(finished.outcome, .completed)
        XCTAssertNotNil(completed.items.first { $0.kind == .user }?.createdAt)
        let second = try await sessions.handle(.send(session: session, text: "second turn", model: nil))
        XCTAssertEqual(second.turns?.count, 2)
        XCTAssertEqual(second.turns?.first, finished)
        let closed = try await sessions.handle(.close(session: session))
        XCTAssertEqual(closed.turns?.first, finished, "Closing a later turn must not replace a previous completion time/status")
        XCTAssertEqual(closed.turns?.last?.status, .closed)
        XCTAssertEqual(closed.turns?.last?.outcome, .cancelled)
        XCTAssertNotNil(closed.turns?.last?.completedAt)
        let read = try await sessions.handle(.read(session: session))
        XCTAssertEqual(read.turns, closed.turns)
        let decoded = try WireJSON.decode(AgentChatSnapshot.self, from: WireJSON.encode(closed))
        XCTAssertEqual(decoded.turns, closed.turns)
        try decoded.validate()
    }

    func testObservedItemDatesAndRunIdentitySurviveProviderReplacements() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback); box.install(runtime); return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .codex))
        let sent = try await sessions.handle(.send(session: session, text: "First", model: nil))
        let runtime = try XCTUnwrap(box.runtime)
        runtime.callback(.item(.init(id: "answer", kind: .assistant, text: "A", isComplete: false)))
        let initial = try await sessions.handle(.read(session: session))
        let first = try XCTUnwrap(initial.items.first { $0.id == "answer" })
        XCTAssertNotNil(first.createdAt)
        XCTAssertEqual(first.workContext?.runID, "native-turn:" + (sent.turns?.last?.userItemID ?? ""))
        runtime.callback(.textDelta(id: "answer", text: "B"))
        runtime.callback(.item(.init(id: "answer", kind: .assistant, text: "AB")))
        let replaced = try await sessions.handle(.read(session: session))
        let final = try XCTUnwrap(replaced.items.first { $0.id == "answer" })
        XCTAssertEqual(final.createdAt, first.createdAt)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(final.updatedAt), try XCTUnwrap(first.updatedAt))
        XCTAssertEqual(final.workContext?.runID, first.workContext?.runID)
        runtime.callback(.status(.idle))
        let next = try await sessions.handle(.send(session: session, text: "Next", model: nil))
        let secondUser = try XCTUnwrap(next.items.last { $0.kind == .user })
        XCTAssertEqual(secondUser.workContext?.runID, "native-turn:" + secondUser.id)
        XCTAssertNotEqual(secondUser.workContext?.runID, first.workContext?.runID)
    }

    func testObservedPlanBodiesRemainBudgetedAndRuntimeFailureKeepsErrorSemantics() async throws {
        let root = try root()
        let content = String(repeating: "Plan detail 🙂 ", count: 4000)
        let detail = try XCTUnwrap(agentRuntimeJSON(["steps": [["id": "step-1", "text": content, "status": "running"]]]))
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = {
                for index in 0..<40 {
                    callback(.item(AgentChatItem(id: "plan-\(index)", kind: .tool, text: "Updated plan", detail: detail,
                        workContext: .init(itemType: "todo_list", sourceStatus: "running", planStatus: "active"))))
                }
                callback(.failure("Observed provider disconnect"))
            }
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .codex))
        let snapshot = try await sessions.handle(.send(session: session, text: "Retain my plan", model: nil))
        XCTAssertLessThanOrEqual(snapshot.items.reduce(0, { $0 + $1.transcriptByteCount }), 512 * 1024)
        let plans = snapshot.items.filter { $0.workContext?.itemType == "todo_list" }
        XCTAssertFalse(plans.isEmpty)
        XCTAssertTrue(plans.contains { $0.detail?.contains("[Earlier text truncated]") == true })
        XCTAssertTrue(plans.allSatisfy { ($0.detail?.utf8.count ?? 0) <= 16 * 1024 })
        let failure = try XCTUnwrap(snapshot.items.last { $0.workContext?.itemType == "error" })
        XCTAssertEqual(failure.text, "Observed provider disconnect")
        XCTAssertEqual(failure.workContext?.sourceStatus, "failed")
        XCTAssertNotNil(failure.createdAt)
        XCTAssertNotNil(failure.workContext?.runID)
        try snapshot.validate()
        XCTAssertLessThan(try WireJSON.encode(snapshot).count, AgentLimits.maxFrame)
    }

    func testLargeTypedToolMetadataIsBoundedWithoutDroppingItsRow() async throws {
        let root = try root()
        let large = String(repeating: "typed result 🙂 ", count: 8000)
        var change = AgentToolActivity(name: "Edit", status: .completed, presentation: .fileChange)
        change.fileChangeDetails = .init(fileName: "changed.swift", diff: large, operations: [
            .init(operation: "update", path: "changed.swift", oldPath: large)
        ])
        var search = AgentToolActivity(name: "Search", status: .completed, presentation: .fileSearch)
        search.fileSearchDetails = .init(pattern: "needle", results: (0..<100).map {
            .init(fileName: "file-\($0).swift", line: 12, preview: large)
        })
        var web = AgentToolActivity(name: "WebSearch", status: .completed, presentation: .webSearch)
        web.searchPatterns = ["query"]
        web.webResults = (0..<100).map { _ in .init(title: "Found", url: "https://example.com", snippet: large) }
        let tools = [change, search, web]
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = {
                for (index, tool) in tools.enumerated() {
                    callback(.item(.init(id: "typed-\(index)", kind: .tool, text: tool.name ?? "Tool", tool: tool)))
                }
                callback(.status(.idle))
            }
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .codex))
        let snapshot = try await sessions.handle(.send(session: session, text: "Inspect typed results", model: nil))
        let retained = snapshot.items.filter { $0.id.hasPrefix("typed-") }
        XCTAssertEqual(retained.count, 3, "Large typed payloads must not remove the tool call itself")
        XCTAssertTrue(retained.allSatisfy { ($0.tool?.transcriptByteCount ?? Int.max) <= 32 * 1024 })
        XCTAssertEqual(retained.first?.tool?.fileChangeDetails?.fileName, "changed.swift")
        XCTAssertEqual(retained.dropFirst().first?.tool?.fileSearchDetails?.results?.first?.fileName, "file-0.swift")
        XCTAssertEqual(retained.last?.tool?.webResults?.first?.title, "Found")
        try snapshot.validate()
        XCTAssertLessThan(try WireJSON.encode(snapshot).count, AgentLimits.maxFrame)
    }

    func testToolMetadataDuplicatesAreBudgetedAndLatestUserAndTurnSurviveOutputTrimming() async throws {
        let root = try root()
        let content = String(repeating: "🙂\0", count: 8000)
        let metadata = AgentToolActivity(name: "Bash", category: .command,
                                         input: String(repeating: "x", count: 20000), output: content, status: .completed,
                                         filePaths: (0..<50).map { "/project/\($0)/" + String(repeating: "p", count: 2000) },
                                         fileChanges: (0..<50).map { .init(path: "/project/\($0)", diff: content, kind: "edit") },
                                         urls: (0..<50).map { "https://example.com/\($0)/" + String(repeating: "u", count: 3000) })
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = {
                for index in 0..<30 {
                    callback(.item(AgentChatItem(id: "tool-\(index)", kind: .tool, text: "Bash", detail: content, tool: metadata)))
                }
                for _ in 0..<20 { callback(.textDelta(id: "answer", text: "continued ")) }
                callback(.status(.idle))
            }
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        let snapshot = try await sessions.handle(.send(session: session, text: "keep this turn header", model: nil))
        XCTAssertLessThanOrEqual(snapshot.items.reduce(0, { $0 + $1.transcriptByteCount }), 512 * 1024)
        XCTAssertEqual(snapshot.items.first { $0.kind == .user }?.text, "keep this turn header")
        XCTAssertEqual(snapshot.turns?.first?.userItemID, snapshot.items.first { $0.kind == .user }?.id)
        XCTAssertNotNil(snapshot.turns?.first?.completedAt)
        let tools = snapshot.items.compactMap(\.tool)
        XCTAssertFalse(tools.isEmpty)
        XCTAssertTrue(tools.contains { $0.input?.hasPrefix("[Earlier text truncated]") == true })
        XCTAssertTrue(tools.contains { $0.output?.contains("[Tool metadata truncated]") == true })
        for tool in tools {
            XCTAssertLessThanOrEqual(tool.filePaths?.count ?? 0, 32)
            XCTAssertLessThanOrEqual(tool.fileChanges?.count ?? 0, 32)
            XCTAssertFalse(tool.output?.contains("�") == true)
            XCTAssertLessThanOrEqual(tool.output?.components(separatedBy: "[Tool metadata truncated]").count ?? 0, 2)
        }
        try snapshot.validate()
        let frame = try WireJSON.encode(snapshot)
        XCTAssertLessThan(frame.count, AgentLimits.maxFrame)
    }

    /// Earlier items of control characters take six times their size once sent. Pages of
    /// them stop where the reply still fits a frame, and together return every item once.
    func testEarlierPagesOfEscapedTextFitAFrame() async throws {
        let root = try root()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in FakeAgentRuntime(callback) })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        let text = String(repeating: "\u{1}", count: 300_000)
        let lines = try (0..<10).map { try JSONEncoder().encode(AgentChatItem(id: "early-\($0)", kind: .assistant, text: text)) + Data([0x0A]) }
        let earlier = root.appendingPathComponent("earlier/\(session).jsonl")
        try FileManager.default.createDirectory(at: earlier.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.reduce(Data(), +).write(to: earlier)

        var returned: [String] = [], before: Int?, pages = 0
        repeat {
            guard case .earlier(let page) = try await sessions.conversation(.earlier(session: session, before: before, limit: 20)) else {
                return XCTFail("Expected earlier items")
            }
            pages += 1
            XCTAssertFalse(page.items.isEmpty)
            XCTAssertNoThrow(try AgentConversationReply.earlier(page).validate())
            XCTAssertLessThan(try WireJSON.encode(AgentConversationReply.earlier(page)).count, AgentLimits.maxFrame)
            returned = page.items.map(\.id) + returned
            before = page.start
        } while (before ?? 0) > 0 && pages < 10
        XCTAssertGreaterThan(pages, 1, "Ten such items take more than a frame")
        XCTAssertEqual(returned, (0..<10).map { "early-\($0)" })
    }

    /// A tool result used to arrive twice, as `detail` and `tool.output`, halving how many
    /// fit. Stored once, twice as many large reads stay in the conversation.
    func testToolBodiesAreStoredOnceAndDroppedItemsAreCountedAcrossTrimsAndRestarts() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let body = String(repeating: "r", count: 15 * 1024)
        func tool(_ index: Int) -> AgentChatItem {
            AgentChatItem(id: "read-\(index)", kind: .tool, text: "Read", detail: body,
                          tool: AgentToolActivity(name: "Read", category: .read, input: "{}", output: body, status: .completed))
        }
        let session = SessionId()
        var omitted = 0
        do {
            let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
                let runtime = FakeAgentRuntime(callback); box.install(runtime); return runtime
            })
            _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
            _ = try await sessions.handle(.send(session: session, text: "read everything", model: nil))
            for index in 0..<40 { box.runtime?.callback(.item(tool(index))) }
            box.runtime?.callback(.status(.idle))
            let first = try await waitForQueue(sessions, session) { $0.status == .idle }
            let reads = first.items.filter { $0.kind == .tool }
            XCTAssertTrue(reads.allSatisfy { $0.detail == nil }, "The body is kept once, in the tool")
            XCTAssertTrue(reads.dropFirst().allSatisfy { $0.tool?.output == body }, "Only the oldest kept read may be clipped")
            XCTAssertGreaterThan(reads.count, 25, "Counted once, far more than 16 large reads fit")
            XCTAssertLessThanOrEqual(first.items.reduce(0) { $0 + $1.transcriptByteCount }, 512 * 1024)
            omitted = try XCTUnwrap(first.omittedItems)
            XCTAssertEqual(omitted, 40 - reads.count)
            // A second trim adds to the count rather than replacing it.
            _ = try await sessions.handle(.send(session: session, text: "again", model: nil))
            for index in 40..<60 { box.runtime?.callback(.item(tool(index))) }
            box.runtime?.callback(.status(.idle))
            let second = try await waitForQueue(sessions, session) { $0.status == .idle && $0.items.contains { $0.id == "read-59" } }
            XCTAssertGreaterThan(second.omittedItems ?? 0, omitted)
            omitted = second.omittedItems ?? 0
            sessions.shutdown()
        }
        let restarted = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in FakeAgentRuntime(callback) })
        defer { restarted.shutdown() }
        let reloaded = try await restarted.handle(.read(session: session))
        XCTAssertEqual(reloaded.omittedItems, omitted, "The count is saved with the conversation")
        // The dropped items are archived in order and come back a page at a time, newest first.
        guard case .earlier(let newest) = try await restarted.conversation(.earlier(session: session, before: nil, limit: 5)) else {
            return XCTFail("Expected earlier items")
        }
        XCTAssertEqual(newest.total, omitted)
        XCTAssertEqual(newest.items.count, 5)
        XCTAssertEqual(newest.start, omitted - 5)
        let oldestRetained = try XCTUnwrap(reloaded.items.first { $0.kind == .tool }?.id)
        let lastArchived = try XCTUnwrap(newest.items.last?.id)
        XCTAssertLessThan(Int(lastArchived.dropFirst(5)) ?? 99, Int(oldestRetained.dropFirst(5)) ?? 0)
        guard case .earlier(let first) = try await restarted.conversation(.earlier(session: session, before: newest.start, limit: 100)) else {
            return XCTFail("Expected earlier items")
        }
        XCTAssertEqual(first.start, 0)
        XCTAssertEqual(first.items.first?.id, "read-0", "Paging reaches the conversation's start")
        XCTAssertEqual(first.items.count + newest.items.count, omitted)
        XCTAssertNoThrow(try AgentConversationReply.earlier(first).validate())
    }

    /// Claude repeats each assistant message at the end of a turn. One already trimmed
    /// must not come back at the end, out of order.
    /// Output kept only its last 16 KiB with no way to see the rest; a file read lost its start.
    func testLongToolOutputIsKeptWholeOnTheServerAndReadsKeepTheirStart() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback); box.install(runtime); return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: session, text: "go", model: nil))
        let log = (0..<2000).map { "log line \($0)" }.joined(separator: "\n")
        let file = (0..<2000).map { "source line \($0)" }.joined(separator: "\n")
        box.runtime?.callback(.item(AgentChatItem(id: "bash", kind: .tool, text: "Bash",
            tool: .init(name: "Bash", category: .command, input: "make", output: log, status: .completed, presentation: .command))))
        box.runtime?.callback(.item(AgentChatItem(id: "read", kind: .tool, text: "Read",
            tool: .init(name: "Read", category: .read, input: "{}", output: file, status: .completed))))
        box.runtime?.callback(.status(.idle))
        let snapshot = try await waitForQueue(sessions, session) { $0.status == .idle }
        let bash = try XCTUnwrap(snapshot.items.first { $0.id == "bash" }?.tool)
        let read = try XCTUnwrap(snapshot.items.first { $0.id == "read" }?.tool)
        XCTAssertEqual(bash.fullOutputBytes, log.utf8.count)
        XCTAssertLessThanOrEqual(bash.output?.utf8.count ?? .max, 16 * 1024)
        XCTAssertTrue(bash.output?.contains("log line 1999") == true, "A command keeps its end")
        XCTAssertTrue(read.output?.hasPrefix("source line 0\n") == true, "A read keeps its start")
        try await Task.sleep(for: .milliseconds(50))
        guard case .toolOutput(let whole) = try await sessions.conversation(.toolOutput(session: session, item: "bash")) else {
            return XCTFail("Unexpected reply")
        }
        XCTAssertEqual(whole.text, log)
        do {
            _ = try await sessions.conversation(.toolOutput(session: session, item: "nothing"))
            XCTFail("Only kept outputs can be read")
        } catch {}
    }

    func testRepeatedMessagesOnlyUpdateItemsTheConversationStillHolds() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback); box.install(runtime); return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: session, text: "hello", model: nil))
        box.runtime?.callback(.item(AgentChatItem(id: "kept", kind: .assistant, text: "Draft", isComplete: false)))
        box.runtime?.callback(.itemUpdate(AgentChatItem(id: "kept", kind: .assistant, text: "Final")))
        box.runtime?.callback(.itemUpdate(AgentChatItem(id: "trimmed", kind: .assistant, text: "Gone")))
        box.runtime?.callback(.status(.idle))
        let snapshot = try await waitForQueue(sessions, session) { $0.status == .idle }
        XCTAssertEqual(snapshot.items.first { $0.id == "kept" }?.text, "Final")
        XCTAssertFalse(snapshot.items.contains { $0.id == "trimmed" })
    }

    func testOlderSnapshotsWithDuplicatedToolBodiesStillLoad() async throws {
        let root = try root()
        let session = SessionId(), project = ProjectId()
        let body = String(repeating: "o", count: 2048)
        var snapshot = AgentChatSnapshot(session: session, project: project, provider: .claude, status: .idle, revision: 4)
        snapshot.items = [AgentChatItem(id: "u", kind: .user, text: "read"),
                          AgentChatItem(id: "t", kind: .tool, text: "Read", detail: body,
                                        tool: AgentToolActivity(name: "Read", category: .read, output: body, status: .completed)),
                          AgentChatItem(id: "todo", kind: .tool, text: "Updated plan", detail: #"{"steps":[]}"#,
                                        workContext: .init(itemType: "todo_list"))]
        let saved: [String: Any] = ["snapshot": try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))),
                                    "directory": root.path]
        try JSONSerialization.data(withJSONObject: saved).write(to: root.appendingPathComponent(session.description + ".json"))
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in FakeAgentRuntime(callback) })
        defer { sessions.shutdown() }
        let loaded = try await sessions.handle(.read(session: session))
        XCTAssertEqual(loaded.items.first { $0.id == "t" }?.tool?.output, body)
        XCTAssertNil(loaded.items.first { $0.id == "t" }?.detail)
        XCTAssertEqual(loaded.items.first { $0.id == "todo" }?.detail, #"{"steps":[]}"#, "Typed cards keep their detail")
        XCTAssertNil(loaded.omittedItems)
    }

    /// An incremental read applied to the client's snapshot gives exactly the full read,
    /// through appends, streamed text and items trimmed away.
    func testIncrementalReadsMatchFullReadsThroughAppendsStreamingAndTrims() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback); box.install(runtime); return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        var held = try await sessions.handle(.send(session: id, text: "start", model: nil))
        func step(_ change: () -> Void, file: StaticString = #filePath, line: UInt = #line) async throws {
            change()
            try await Task.sleep(for: .milliseconds(20))
            let full = try await sessions.handle(.read(session: id))
            guard case .delta(let delta) = try await sessions.conversation(.readSince(session: id, revision: held.revision)) else {
                return XCTFail("Unexpected reply", file: file, line: line)
            }
            XCTAssertLessThan(delta.snapshot.items.count, max(2, full.items.count), "Only changed items travel", file: file, line: line)
            let applied = try XCTUnwrap(delta.applied(to: held), file: file, line: line)
            XCTAssertEqual(applied, full, file: file, line: line)
            held = applied
        }
        try await step { box.runtime?.callback(.item(AgentChatItem(id: "a1", kind: .assistant, text: "Hel", isComplete: false))) }
        try await step { box.runtime?.callback(.textDelta(id: "a1", text: "lo")) }
        try await step {
            for index in 0..<520 { box.runtime?.callback(.item(AgentChatItem(id: "t\(index)", kind: .tool, text: "Read", isComplete: true))) }
        }
        XCTAssertGreaterThan(held.omittedItems ?? 0, 0, "The trim removed the oldest items")
        try await step { box.runtime?.callback(.status(.idle)) }
        guard case .delta(let unchanged) = try await sessions.conversation(.readSince(session: id, revision: held.revision)) else {
            return XCTFail("Unexpected reply")
        }
        XCTAssertTrue(unchanged.snapshot.items.isEmpty)
        XCTAssertEqual(unchanged.applied(to: held), held)
    }

    func testIncrementalReadAfterARestartSendsEverything() async throws {
        let root = try root()
        let id = SessionId()
        var held: AgentChatSnapshot
        do {
            let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in FakeAgentRuntime(callback) })
            _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
            held = try await sessions.handle(.send(session: id, text: "start", model: nil))
            sessions.shutdown()
        }
        let restarted = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in FakeAgentRuntime(callback) })
        defer { restarted.shutdown() }
        let full = try await restarted.handle(.read(session: id))
        held.revision = full.revision - 1
        guard case .delta(let delta) = try await restarted.conversation(.readSince(session: id, revision: held.revision)) else {
            return XCTFail("Unexpected reply")
        }
        XCTAssertEqual(delta.snapshot.items.map(\.id), full.items.map(\.id), "Unknown history means every item is sent")
    }

    func testStopWhileInitialAccessConfigurationIsPendingCannotSubmitLater() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let gate = AgentSubmissionGate()
        let configuring = expectation(description: "initial access is pending")
        let configured = expectation(description: "old access operation finishes")
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onAccess = { _ in
                configuring.fulfill()
                await gate.wait()
                configured.fulfill()
            }
            runtime.onSend = { XCTFail("A cancelled startup must not send after configuration resumes") }
            box.install(runtime)
            return runtime
        })
        // Only the provider is followed here; a checkpoint's outcome would change the conversation later.
        sessions.capturesCheckpoints = false
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        let sending = Task { try await sessions.handle(.send(session: session, text: "cancel before launch", model: nil)) }
        await fulfillment(of: [configuring], timeout: 2)
        let stopped = try await sessions.handle(.interrupt(session: session))
        XCTAssertEqual(stopped.status, .idle)
        let submitted = try await sending.value
        XCTAssertEqual(submitted, stopped)
        await gate.release()
        await fulfillment(of: [configured], timeout: 2)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(box.runtime?.models.count, 0)
        let read = try await sessions.handle(.read(session: session))
        XCTAssertEqual(read, stopped)
        XCTAssertNil(read.providerSession)
    }


}

extension AgentSessionsTests {
    private func waitForQueue(_ sessions: AgentSessions, _ id: SessionId,
                              until predicate: (AgentChatSnapshot) -> Bool) async throws -> AgentChatSnapshot {
        for _ in 0..<300 {
            let snapshot = try await sessions.handle(.read(session: id))
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AgentRuntimeError("Queue did not settle")
    }

    func testDurableQueueDeduplicationEditOrderingStopAndResume() async throws {
        let root = try root()
        let box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback); runtime.onSteer = {}; box.install(runtime); return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        let first = AgentPrompt(text: "First", model: nil, effort: nil, provider: .codex, planMode: false)
        _ = try await sessions.handle(.submit(session: id, prompt: first))
        _ = try await waitForQueue(sessions, id) { $0.status == .working && $0.queuedPrompts?.isEmpty == true }
        _ = try await sessions.handle(.submit(session: id, prompt: first))
        XCTAssertEqual(box.runtime?.models.count, 1)
        let second = AgentPrompt(text: "Second", model: nil, effort: nil, provider: .codex, planMode: false)
        let third = AgentPrompt(text: "Third", model: nil, effort: nil, provider: .codex, planMode: false)
        _ = try await sessions.handle(.submit(session: id, prompt: second))
        _ = try await sessions.handle(.submit(session: id, prompt: third))
        let moved = try await sessions.handle(.moveQueued(session: id, id: third.id, beforeID: second.id, expectedRevision: 0))
        XCTAssertEqual(moved.queuedPrompts?.map(\.id), [third.id, second.id])
        let edited = try await sessions.handle(.editQueued(session: id, id: third.id, text: "Edited third", expectedRevision: 1))
        XCTAssertEqual(edited.queuedPrompts?.first?.text, "Edited third")
        do { _ = try await sessions.handle(.removeQueued(session: id, id: third.id, expectedRevision: 1)); XCTFail("Stale removal must fail") } catch {}
        let stopped = try await sessions.handle(.interrupt(session: id))
        XCTAssertEqual(stopped.queuePaused, true)
        XCTAssertEqual(stopped.queuedPrompts?.count, 2)
        XCTAssertEqual(box.runtime?.models.count, 1)
        _ = try await sessions.handle(.resumeQueue(session: id))
        let resumed = try await waitForQueue(sessions, id) { $0.status == .working && $0.queuedPrompts?.count == 1 }
        XCTAssertEqual(resumed.items.last { $0.kind == .user }?.text, "Edited third")
        box.runtime?.callback(.status(.idle))
        let drained = try await waitForQueue(sessions, id) { $0.status == .working && $0.queuedPrompts?.isEmpty == true }
        XCTAssertEqual(drained.items.filter { $0.kind == .user }.map(\.text), ["First", "Edited third", "Second"])
        XCTAssertEqual(box.runtime?.models.count, 3)
    }

    /// Claude's answer to a finished background agent used to stream while the
    /// conversation stayed idle, with no turn and Stop disabled.
    func testTurnTheProviderBeginsItselfIsRecordedAndKeepsTheQueueWaiting() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback); box.install(runtime); return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.submit(session: id, prompt: AgentPrompt(text: "Launch", model: nil, effort: nil,
                                                                               provider: .claude, planMode: false)))
        _ = try await waitForQueue(sessions, id) { $0.status == .working && $0.queuedPrompts?.isEmpty == true }
        box.runtime?.callback(.subagents([AgentSubagent(id: "a1", toolUseID: "toolu_agent", description: "bg probe", background: true)]))
        box.runtime?.callback(.subagentSteps(toolUseID: "toolu_agent", items: [AgentChatItem(id: "step", kind: .assistant, text: "DONE")]))
        box.runtime?.callback(.status(.idle))
        let idle = try await waitForQueue(sessions, id) { $0.status == .idle }
        XCTAssertEqual(idle.subagents?.first?.steps, 1)
        guard case .subagentSteps(let steps) = try await sessions.conversation(.subagentSteps(session: id, toolUseID: "toolu_agent")) else {
            return XCTFail("Unexpected reply")
        }
        XCTAssertEqual(steps.items.map(\.text), ["DONE"])

        box.runtime?.callback(.providerTurn(reason: "Background agent “bg probe” finished"))
        box.runtime?.callback(.item(AgentChatItem(id: "answer", kind: .assistant, text: "It finished.", isComplete: false)))
        let working = try await waitForQueue(sessions, id) { $0.status == .working }
        let anchor = try XCTUnwrap(working.items.last { $0.kind == .user })
        XCTAssertTrue(anchor.isProviderTurn)
        XCTAssertEqual(working.turns?.last?.userItemID, anchor.id)
        XCTAssertNil(working.turns?.last?.completedAt)
        XCTAssertNoThrow(try working.validate(), "Older apps validate turns against user rows")
        // A prompt sent now waits in the queue; the provider's turn is not interrupted.
        _ = try await sessions.handle(.submit(session: id, prompt: AgentPrompt(text: "Next", model: nil, effort: nil,
                                                                               provider: .claude, planMode: false)))
        let queued = try await sessions.handle(.read(session: id))
        XCTAssertEqual(queued.queuedPrompts?.map(\.text), ["Next"])
        XCTAssertEqual(box.runtime?.models.count, 1)
        box.runtime?.callback(.status(.idle))
        let next = try await waitForQueue(sessions, id) { $0.status == .working && $0.queuedPrompts?.isEmpty == true }
        XCTAssertNotNil(next.turns?.first { $0.userItemID == anchor.id }?.completedAt)
        XCTAssertEqual(next.items.filter { $0.kind == .user && !$0.isProviderTurn }.map(\.text), ["Launch", "Next"])
    }

    func testRestartAndProviderChangesSayWhichRunningAgentsStopped() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let id = SessionId()
        do {
            let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
                let runtime = FakeAgentRuntime(callback); box.install(runtime); return runtime
            })
            _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
            _ = try await sessions.handle(.send(session: id, text: "Launch", model: nil))
            box.runtime?.callback(.subagents([AgentSubagent(id: "a1", description: "one", background: true),
                                              AgentSubagent(id: "a2", description: "two", background: true)]))
            box.runtime?.callback(.status(.idle))
            _ = try await waitForQueue(sessions, id) { $0.status == .idle && $0.subagents?.count == 2 }
            sessions.shutdown()
        }
        let restarted = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            FakeAgentRuntime(callback)
        })
        defer { restarted.shutdown() }
        let snapshot = try await restarted.handle(.read(session: id))
        XCTAssertNil(snapshot.subagents)
        XCTAssertTrue(snapshot.items.contains { $0.kind == .notice && $0.text == "Stopped 2 running agents because the server restarted." })
    }

    func testSubmitWhileIdleRepliesWithTheMessageAlreadyInTheConversation() async throws {
        let root = try root()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = { try await Task.sleep(for: .seconds(30)) } // A slow provider startup.
            return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        let prompt = AgentPrompt(text: "Hello", model: nil, effort: nil, provider: .claude, planMode: false)
        let reply = try await sessions.handle(.submit(session: id, prompt: prompt))
        XCTAssertEqual(reply.status, .working)
        XCTAssertEqual(reply.items.last { $0.kind == .user }?.text, "Hello",
                       "The reply must not leave the message only in the queue while the provider starts")
        XCTAssertEqual(reply.queuedPrompts?.allSatisfy { $0.state == .delivering }, true)
    }

    func testNewMessageAfterStopResumesTheQueueAndSendsAtOnce() async throws {
        let root = try root()
        let box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback); box.install(runtime); return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.submit(session: id, prompt: AgentPrompt(text: "First", model: nil, effort: nil,
                                                                               provider: .codex, planMode: false)))
        _ = try await waitForQueue(sessions, id) { $0.status == .working && $0.queuedPrompts?.isEmpty == true }
        let held = AgentPrompt(text: "Later", model: nil, effort: nil, provider: .codex, planMode: false)
        _ = try await sessions.handle(.submit(session: id, prompt: held))
        let stopped = try await sessions.handle(.interrupt(session: id))
        XCTAssertEqual(stopped.status, .idle)
        XCTAssertEqual(stopped.queuePaused, true)
        XCTAssertEqual(stopped.queuedPrompts?.map(\.text), ["Later"])
        let next = AgentPrompt(text: "Carry on", model: nil, effort: nil, provider: .codex, planMode: false)
        _ = try await sessions.handle(.submit(session: id, prompt: next))
        let resumed = try await waitForQueue(sessions, id) { $0.status == .working && $0.queuedPrompts?.count == 1 }
        XCTAssertNotEqual(resumed.queuePaused, true)
        XCTAssertEqual(resumed.items.filter { $0.kind == .user }.map(\.text), ["First", "Carry on"],
                       "The new message goes ahead of the prompt the stop held")
        box.runtime?.callback(.status(.idle))
        let drained = try await waitForQueue(sessions, id) { $0.status == .working && $0.queuedPrompts?.isEmpty == true }
        XCTAssertEqual(drained.items.filter { $0.kind == .user }.map(\.text), ["First", "Carry on", "Later"])
    }

    func testStopAfterTheTurnFinishedOnlyHoldsTheQueue() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onInterrupt = { XCTFail("An idle agent has nothing to interrupt") }
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.send(session: id, text: "First", model: nil))
        box.runtime?.callback(.status(.idle))
        let finished = try await waitForQueue(sessions, id) { $0.status == .idle }
        let stopped = try await sessions.handle(.interrupt(session: id))
        XCTAssertEqual(stopped.status, .idle)
        XCTAssertEqual(stopped.queuePaused, true)
        XCTAssertEqual(stopped.items, finished.items, "A stop that races the end of a turn adds no notice")
        XCTAssertEqual(stopped.turns?.last?.outcome, .completed)
    }

    func testStopWhenTheRuntimeHasNoTurnToInterruptKeepsTheConversation() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            // As Codex does before a compaction reports its turn.
            runtime.onInterrupt = { callback(.status(.closed)) }
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.send(session: id, text: "/compact", model: nil))
        let first = try XCTUnwrap(box.runtime)
        _ = try await sessions.handle(.interrupt(session: id))
        let stopped = try await waitForQueue(sessions, id) { $0.status != .working }
        XCTAssertEqual(stopped.status, .idle, "Stopping must not end the conversation")
        XCTAssertEqual(stopped.turns?.last?.outcome, .interrupted)
        let next = try await sessions.handle(.send(session: id, text: "Carry on", model: nil))
        XCTAssertEqual(next.status, .working)
        XCTAssertFalse(first === box.runtime)
    }

    func testNewMessageAfterFailureStartsANewTurn() async throws {
        let root = try root()
        let box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback); box.install(runtime); return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.send(session: id, text: "First", model: nil))
        let first = try XCTUnwrap(box.runtime)
        first.callback(.failure("Provider crashed"))
        let failed = try await waitForQueue(sessions, id) { $0.status == .failed }
        XCTAssertEqual(failed.queuePaused, true)
        _ = try await sessions.handle(.submit(session: id, prompt: AgentPrompt(text: "Try again", model: nil, effort: nil,
                                                                               provider: .codex, planMode: false)))
        let retried = try await waitForQueue(sessions, id) { $0.status == .working && $0.queuedPrompts?.isEmpty == true }
        XCTAssertEqual(retried.items.last { $0.kind == .user }?.text, "Try again")
        XCTAssertFalse(first === box.runtime, "A failed provider is replaced, resuming its conversation")
    }

    func testQueueStorageFailureDoesNotDeliverAndRetainsPrompt() async throws {
        let root = try root()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            XCTFail("A queue that cannot be saved must never launch a provider")
            return FakeAgentRuntime(callback)
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        try Data("block directory creation".utf8).write(to: root.appendingPathComponent("inbox"))
        let prompt = AgentPrompt(text: "Keep this", model: nil, effort: nil, provider: .codex, planMode: false)
        do { _ = try await sessions.handle(.submit(session: id, prompt: prompt)); XCTFail("Must report storage failure") } catch {}
        let state = try await sessions.handle(.read(session: id))
        XCTAssertEqual(state.queuePaused, true)
        XCTAssertEqual(state.queuedPrompts?.first?.text, "Keep this")
    }

    func testRestartPreservesQueueWithoutAutomaticallyExecutingIt() async throws {
        let root = try root()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in FakeAgentRuntime(callback) })
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.send(session: id, text: "Busy", model: nil))
        let prompt = AgentPrompt(text: "After restart", model: nil, effort: nil, provider: .codex, planMode: false)
        _ = try await sessions.handle(.submit(session: id, prompt: prompt))
        sessions.shutdown()
        let restored = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            XCTFail("Recovery must not execute queued prompts")
            return FakeAgentRuntime(callback)
        })
        defer { restored.shutdown() }
        let snapshot = try await restored.handle(.read(session: id))
        XCTAssertEqual(snapshot.queuePaused, true)
        XCTAssertEqual(snapshot.queuedPrompts?.map(\.id), [prompt.id])
        let duplicate = try await restored.handle(.submit(session: id, prompt: prompt))
        XCTAssertEqual(duplicate.queuedPrompts?.count, 1)
        let closed = try await restored.handle(.close(session: id))
        XCTAssertTrue(closed.queuedPrompts?.isEmpty == true)
    }
}

extension AgentSessionsTests {
    func testSendNowSteersOnceAndStaleSecondClickCannotDeliverAgain() async throws {
        let root = try root()
        let steers = AgentEventCount()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback); runtime.onSteer = { steers.increment() }; return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.send(session: id, text: "Work", model: nil))
        let prompt = AgentPrompt(text: "Change direction", model: nil, effort: nil, provider: .codex, planMode: false)
        _ = try await sessions.handle(.submit(session: id, prompt: prompt))
        _ = try await sessions.handle(.deliverQueued(session: id, id: prompt.id, expectedRevision: 0))
        do { _ = try await sessions.handle(.deliverQueued(session: id, id: prompt.id, expectedRevision: 0)); XCTFail("Duplicate delivery must be rejected") } catch {}
        let final = try await waitForQueue(sessions, id) { $0.queuedPrompts?.isEmpty == true }
        XCTAssertEqual(steers.count, 1)
        XCTAssertEqual(final.items.filter { $0.kind == .user }.map(\.text), ["Work", "Change direction"])
        _ = try await sessions.handle(.submit(session: id, prompt: prompt))
        XCTAssertEqual(steers.count, 1)
    }

    func testLargePendingQuestionSurvivesTranscriptTrimmingAndAnswerRetryIsIdempotent() async throws {
        let root = try root()
        let box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback); box.install(runtime); return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.send(session: id, text: "Start", model: nil))
        let form = AgentQuestionnaire(questions: [.init(id: "choice", title: "Choose", options: [.init(label: "A", description: String(repeating: "details ", count: 700))])])
        box.runtime?.callback(.item(.init(id: "questions", kind: .approval, text: "Questions", isComplete: false, questionnaire: form)))
        box.runtime?.callback(.status(.waiting))
        for i in 0..<600 { box.runtime?.callback(.item(.init(id: "overflow-\(i)", kind: .assistant, text: String(repeating: "x", count: 3000)))) }
        let state = try await waitForQueue(sessions, id) { $0.items.contains { $0.id == "overflow-599" } }
        XCTAssertEqual(state.items.first { $0.id == "questions" }?.questionnaire, form)
        XCTAssertNoThrow(try state.validate())
        box.runtime?.callback(.item(.init(id: "questions", kind: .approval, text: "Answered")))
        _ = try await waitForQueue(sessions, id) { $0.items.first { $0.id == "questions" }?.isComplete == true }
        let repeated = try await sessions.handle(.answer(session: id, request: "questions", answers: ["choice": ["A"]], cancelled: false))
        XCTAssertEqual(repeated.items.first { $0.id == "questions" }?.text, "Answered")
    }

    func testAlwaysAllowedToolsOutliveRestartUntilAskIsChosen() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let factory: AgentSessions.Factory = { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = {
                callback(.item(AgentChatItem(id: "bash", kind: .approval, text: "Bash", isComplete: false)))
                callback(.item(AgentChatItem(id: "question", kind: .approval, text: "AskUserQuestion", isComplete: false)))
                callback(.status(.waiting))
            }
            box.install(runtime)
            return runtime
        }
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: factory)
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: id, text: "hello", model: nil))
        do {
            _ = try await sessions.handle(.approve(session: id, request: "question", allow: true, always: true))
            XCTFail("A question is never allowed for the rest of the conversation")
        } catch {}
        _ = try await sessions.handle(.approve(session: id, request: "bash", allow: true, always: true))
        sessions.shutdown()

        let restored = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: factory)
        defer { restored.shutdown() }
        _ = try await restored.handle(.send(session: id, text: "again", model: nil))
        XCTAssertEqual(box.runtime?.alwaysAllowed, ["Bash"])
        _ = try await restored.handle(.setAccess(session: id, mode: .ask))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(box.runtime?.alwaysAllowed, [])
    }

    func testConversationsClosedLongAgoArePrunedWithTheirFiles() async throws {
        let root = try root()
        let closed = SessionId(), open = SessionId()
        do {
            let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, retention: .deleteClosed(after: AgentSessions.closedRetention), factory: { _, _, _, callback in FakeAgentRuntime(callback) })
            _ = try await sessions.handle(.create(session: closed, project: ProjectId(), provider: .claude))
            _ = try await sessions.handle(.create(session: open, project: ProjectId(), provider: .claude))
            _ = try await sessions.handle(.close(session: closed))
            sessions.shutdown()
        }
        let outputs = root.appendingPathComponent("outputs/" + closed.description, isDirectory: true)
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        try dropCloseTime(root.appendingPathComponent(closed.description + ".json"))
        let old = Date().addingTimeInterval(-AgentSessions.closedRetention - 86_400)
        for id in [closed, open] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appendingPathComponent(id.description + ".json").path)
        }
        let restarted = try AgentSessions(root: root, projectDirectory: { _ in root.path }, retention: .deleteClosed(after: AgentSessions.closedRetention), factory: { _, _, _, callback in FakeAgentRuntime(callback) })
        defer { restarted.shutdown() }
        _ = try await restarted.handle(.read(session: open))
        do {
            _ = try await restarted.handle(.read(session: closed))
            XCTFail("A conversation closed long ago is gone")
        } catch {}
        restarted.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(closed.description + ".json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputs.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(open.description + ".json").path),
                      "An open conversation stays however old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("removing/" + closed.description + ".json").path),
                       "A finished deletion leaves no record")
    }

    /// A closed conversation saved by a run that stopped long ago, with a tool output kept.
    private func expiredConversation(in root: URL) async throws -> (session: SessionId, record: URL, outputs: URL) {
        let session = SessionId()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, retention: .deleteClosed(after: AgentSessions.closedRetention), factory: { _, _, _, callback in FakeAgentRuntime(callback) })
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.close(session: session))
        sessions.shutdown()
        let record = root.appendingPathComponent(session.description + ".json")
        try dropCloseTime(record)
        let old = Date().addingTimeInterval(-AgentSessions.closedRetention - 86_400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: record.path)
        let outputs = root.appendingPathComponent("outputs/" + session.description, isDirectory: true)
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: outputs.appendingPathComponent("tool.txt"))
        return (session, record, outputs)
    }

    /// Makes `record` one saved before close times were kept, whose age is its last change.
    private func dropCloseTime(_ record: URL) throws {
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        saved["closedAt"] = nil
        try JSONSerialization.data(withJSONObject: saved).write(to: record)
    }

    private func restart(_ root: URL) throws {
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, retention: .deleteClosed(after: AgentSessions.closedRetention), factory: { _, _, _, callback in FakeAgentRuntime(callback) })
        sessions.shutdown()
    }

    /// Permissions are what these tests deny; root ignores them.
    private func skipAsRoot() throws {
        try XCTSkipIf(geteuid() == 0, "Root ignores file permissions")
    }

    /// Takes away `mode` from `folder` for the rest of the test, or until given back.
    private func restrict(_ folder: URL, to mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: folder.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
    }

    /// Marks the expired conversation saved at `record` as one a clear left, its earlier
    /// messages in `archive`.
    private func markCleared(_ record: URL, into archive: SessionId) throws {
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        var snapshot = try XCTUnwrap(saved["snapshot"] as? [String: Any])
        snapshot["resetID"] = archive.description
        saved["snapshot"] = snapshot
        try JSONSerialization.data(withJSONObject: saved).write(to: record)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-AgentSessions.closedRetention - 86_400)],
                                              ofItemAtPath: record.path)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// A finished turn's checkpoint in `repo`, and the refs it pins.
    private func checkpoint(in repo: GitTestRepo) throws -> AgentCheckpointRecord {
        let store = AgentCheckpointStore()
        try repo.write("file.txt", "before \(UUID())\n")
        let before = try store.capture(directory: repo.path)
        try repo.write("file.txt", "after \(UUID())\n")
        return AgentCheckpointRecord(before: before, after: try store.capture(directory: repo.path), files: [])
    }

    private func pins(_ snapshot: AgentCheckpointStore.Snapshot, in repo: GitTestRepo) -> Bool {
        (try? repo.run("rev-parse", "--verify", "--quiet", snapshot.reference)) != nil
    }

    private func save(_ record: AgentCheckpointRecord, as name: String, for session: SessionId, in root: URL) throws -> URL {
        let folder = root.appendingPathComponent("checkpoints/\(session)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name + ".json")
        try JSONEncoder().encode(record).write(to: file)
        return file
    }

    /// A deletion cut short, as by a crash after the record moved out, finishes at the next start.
    func testADeletionCutShortFinishesAtTheNextStart() async throws {
        let root = try root(), expired = try await expiredConversation(in: root)
        let attachments = root.appendingPathComponent("attachments/" + expired.session.description, isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        let record = root.appendingPathComponent("removing/" + expired.session.description + ".json")
        try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: expired.record, to: record)

        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, retention: .deleteClosed(after: AgentSessions.closedRetention), factory: { _, _, _, callback in FakeAgentRuntime(callback) })
        do {
            _ = try await sessions.handle(.read(session: expired.session))
            XCTFail("A deleted conversation stays deleted")
        } catch {}
        sessions.shutdown()
        for path in [expired.outputs, attachments, record] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.path), path.path)
        }
    }

    /// Files that can't go yet keep the deleted conversation's record for another try,
    /// while the conversation itself no longer loads.
    func testADeletionThatCannotFinishKeepsItsRecordForTheNextStart() async throws {
        try skipAsRoot()
        let root = try root(), expired = try await expiredConversation(in: root)
        let outputs = expired.outputs.deletingLastPathComponent()
        try restrict(outputs, to: 0o500)

        try restart(root)
        let record = root.appendingPathComponent("removing/" + expired.session.description + ".json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.record.path), "The record moved out of the conversations")
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "It waits for the files that remain")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expired.outputs.path))

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outputs.path)
        try restart(root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.outputs.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    }

    /// A record that can't move out, as in a store this run can't change, keeps everything.
    func testAnExpiredConversationWhoseRecordCannotMoveKeepsItsFiles() async throws {
        try skipAsRoot()
        let root = try root(), expired = try await expiredConversation(in: root)
        // The folder for deletions exists, so it is the move itself that fails.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("removing"), withIntermediateDirectories: true)
        try restrict(root, to: 0o500)

        try restart(root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expired.record.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: expired.outputs.appendingPathComponent("tool.txt").path))
    }

    /// A file behind a folder this run can't search is still there, not deleted.
    func testFilesThatCannotBeSeenAreNotTakenAsDeleted() async throws {
        try skipAsRoot()
        let root = try root(), expired = try await expiredConversation(in: root)
        let outputs = expired.outputs.deletingLastPathComponent()
        try restrict(outputs, to: 0o600)

        try restart(root)
        let record = root.appendingPathComponent("removing/\(expired.session).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "The deletion waits for the outputs it can't reach")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outputs.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expired.outputs.appendingPathComponent("tool.txt").path))
        try restart(root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.outputs.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    }

    /// An expired record restored beside its own unfinished deletion is deleted again; the
    /// earlier deletion's record must not take the new one with it. The writer waits until
    /// startup has queued everything, so the outcome can't depend on which runs first.
    func testAnExpiredRecordRestoredBesideItsDeletionIsDeletedAgain() async throws {
        try skipAsRoot()
        let root = try root(), expired = try await expiredConversation(in: root)
        let record = root.appendingPathComponent("removing/\(expired.session).json")
        try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: expired.record, to: record)
        try restrict(expired.outputs.deletingLastPathComponent(), to: 0o500)

        let writer = DispatchQueue(label: "held writer")
        writer.suspend()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path },
                                         retention: .deleteClosed(after: AgentSessions.closedRetention), writer: writer,
                                         factory: { _, _, _, callback in FakeAgentRuntime(callback) })
        writer.resume()
        sessions.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.record.path), "The record moved out again")
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "The deletion keeps a record for what remains")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: expired.outputs.deletingLastPathComponent().path)
        try restart(root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.outputs.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    }

    /// A ref Git can't remove yet, as behind another process's lock, keeps its checkpoint
    /// record and the deletion's until a later start removes it; the other ref goes now.
    func testACheckpointRefGitCannotRemoveYetIsRemovedAtALaterStart() async throws {
        let root = try root(), repo = try GitTestRepo(commit: true), expired = try await expiredConversation(in: root)
        let record = try checkpoint(in: repo)
        let file = try save(record, as: UUID().uuidString, for: expired.session, in: root)
        let lock = URL(fileURLWithPath: repo.path).appendingPathComponent(".git/" + record.before.reference + ".lock")
        try Data().write(to: lock)

        try restart(root)
        let deletion = root.appendingPathComponent("removing/\(expired.session).json")
        XCTAssertTrue(pins(record.before, in: repo), "The locked ref stays")
        XCTAssertFalse(pins(record.after, in: repo), "The other ref goes on its own")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Its checkpoint record stays to try again")
        XCTAssertTrue(FileManager.default.fileExists(atPath: deletion.path))

        try FileManager.default.removeItem(at: lock)
        try restart(root)
        XCTAssertFalse(pins(record.before, in: repo))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: deletion.path))
    }

    /// An interrupted clear leaves the archive's checkpoint records beside the cleared
    /// conversation's own. Deleting that conversation keeps the archive's refs.
    func testDeletingAClearedConversationKeepsItsArchivesCheckpoints() async throws {
        let root = try root(), repo = try GitTestRepo(commit: true), expired = try await expiredConversation(in: root)
        let archive = SessionId()
        try markCleared(expired.record, into: archive)
        let own = try checkpoint(in: repo), archived = try checkpoint(in: repo)
        _ = try save(own, as: UUID().uuidString, for: expired.session, in: root)
        let turn = UUID().uuidString
        _ = try save(archived, as: turn, for: expired.session, in: root)
        let archiveCopy = try save(archived, as: turn, for: archive, in: root)

        try restart(root)
        XCTAssertFalse(pins(own.before, in: repo))
        XCTAssertFalse(pins(own.after, in: repo))
        XCTAssertTrue(pins(archived.before, in: repo), "The archive's checkpoint keeps its refs")
        XCTAssertTrue(pins(archived.after, in: repo))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveCopy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("checkpoints/\(expired.session)").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("removing/\(expired.session).json").path))
    }

    /// A record that came back, as from a backup, wins over its unfinished deletion.
    func testAConversationRestoredDuringItsDeletionKeepsItsFiles() async throws {
        let root = try root(), expired = try await expiredConversation(in: root)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: expired.record.path)
        let attachment = root.appendingPathComponent("attachments/" + expired.session.description + "/image.png")
        try FileManager.default.createDirectory(at: attachment.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("png".utf8).write(to: attachment)
        let record = root.appendingPathComponent("removing/" + expired.session.description + ".json")
        try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: expired.record, to: record)

        try restart(root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: expired.record.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    }

    /// An archive whose checkpoint records can't be read yet may own the refs a deleted
    /// conversation's records name: they stay, and the deletion waits until it can tell.
    func testDeletingAClearedConversationWaitsForAnArchiveItCannotRead() async throws {
        try skipAsRoot()
        let root = try root(), repo = try GitTestRepo(commit: true), expired = try await expiredConversation(in: root)
        let archive = SessionId()
        try markCleared(expired.record, into: archive)
        let shared = try checkpoint(in: repo), turn = UUID().uuidString
        _ = try save(shared, as: turn, for: expired.session, in: root)
        _ = try save(shared, as: turn, for: archive, in: root)
        let archived = root.appendingPathComponent("checkpoints/\(archive)", isDirectory: true)
        try restrict(archived, to: 0o000)

        try restart(root)
        let deletion = root.appendingPathComponent("removing/\(expired.session).json")
        XCTAssertTrue(pins(shared.before, in: repo))
        XCTAssertTrue(pins(shared.after, in: repo))
        XCTAssertTrue(exists(deletion), "The deletion waits for the archive")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: archived.path)
        try restart(root)
        XCTAssertTrue(pins(shared.before, in: repo), "The archive's refs stay")
        XCTAssertTrue(pins(shared.after, in: repo))
        XCTAssertFalse(exists(root.appendingPathComponent("checkpoints/\(expired.session)")))
        XCTAssertFalse(exists(deletion))
    }

    /// A record whose details are damaged still names its refs, which go; one that names
    /// none that can be read stays with the deletion.
    func testDamagedCheckpointRecordsNeverLoseTheirRefs() async throws {
        let root = try root(), repo = try GitTestRepo(commit: true), expired = try await expiredConversation(in: root)
        let record = try checkpoint(in: repo)
        let damaged = try save(record, as: UUID().uuidString, for: expired.session, in: root)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: damaged)) as? [String: Any])
        json["files"] = "not a list"
        try JSONSerialization.data(withJSONObject: json).write(to: damaged)
        let unreadable = damaged.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".json")
        try Data("{ not a record".utf8).write(to: unreadable)

        try restart(root)
        XCTAssertFalse(pins(record.before, in: repo))
        XCTAssertFalse(pins(record.after, in: repo))
        XCTAssertFalse(exists(damaged))
        XCTAssertTrue(exists(unreadable), "A record whose refs can't be read stays")
        XCTAssertTrue(exists(root.appendingPathComponent("removing/\(expired.session).json")))
    }

    /// A conversation with one checkpointed turn, cleared once into `first`, and the copy
    /// of that checkpoint a first clear that couldn't retire it would leave behind.
    private func clearedWithLeftover(_ storage: URL, repo: GitTestRepo)
        async throws -> (sessions: AgentSessions, id: SessionId, first: SessionId, revision: UInt64, leftover: URL, record: AgentCheckpointRecord) {
        try repo.write("file.txt", "before\n")
        try repo.commit("initial")
        let directory = repo.path
        let sessions = try AgentSessions(root: storage, projectDirectory: { _ in directory }, factory: { _, _, _, callback in
            SkillCaptureRuntime(callback) { try "after\n".write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8) }
        })
        let id = SessionId(), first = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: id, text: "Change this file", model: nil))
        let old = try await waitForQueue(sessions, id) { $0.status == .idle && $0.turns?.first?.checkpoint != nil }
        let checkpoint = try XCTUnwrap(old.turns?.first?.checkpoint)
        let cleared = try await sessions.handle(.clear(session: id, archive: first, expectedRevision: old.revision))
        let archivedRecord = storage.appendingPathComponent("checkpoints/\(first)/\(checkpoint.id).json")
        let record = try JSONDecoder().decode(AgentCheckpointRecord.self, from: Data(contentsOf: archivedRecord))
        let leftover = storage.appendingPathComponent("checkpoints/\(id)/\(checkpoint.id).json")
        try FileManager.default.createDirectory(at: leftover.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: archivedRecord, to: leftover)
        return (sessions, id, first, cleared.revision, leftover, record)
    }

    /// A second clear before the store restarts leaves an earlier clear's leftover with its
    /// archive, rather than taking it into its own, where cleanup would unpin its refs.
    func testASecondClearLeavesTheFirstArchivesCheckpointsAlone() async throws {
        let storage = try root(), repo = try GitTestRepo(commit: false)
        let state = try await clearedWithLeftover(storage, repo: repo)
        let second = SessionId()
        _ = try await state.sessions.handle(.clear(session: state.id, archive: second, expectedRevision: state.revision))
        state.sessions.shutdown()
        XCTAssertFalse(exists(storage.appendingPathComponent("checkpoints/\(second)/\(state.leftover.lastPathComponent)")),
                       "The second archive took only the conversation's own checkpoints")

        let restored = try AgentSessions(root: storage, projectDirectory: { _ in repo.path })
        restored.shutdown()
        XCTAssertTrue(pins(state.record.before, in: repo), "The first archive's refs stay")
        XCTAssertTrue(pins(state.record.after, in: repo))
    }

    /// While an earlier archive can't be read, a second clear can't tell its leftovers from
    /// the conversation's own, so it waits; the conversation stays as it was.
    func testASecondClearWaitsForAnEarlierArchiveItCannotRead() async throws {
        try skipAsRoot()
        let storage = try root(), repo = try GitTestRepo(commit: false)
        let state = try await clearedWithLeftover(storage, repo: repo)
        defer { state.sessions.shutdown() }
        let archived = storage.appendingPathComponent("checkpoints/\(state.first)", isDirectory: true)
        try restrict(archived, to: 0o000)
        let second = SessionId()
        do {
            _ = try await state.sessions.handle(.clear(session: state.id, archive: second, expectedRevision: state.revision))
            XCTFail("The clear must wait")
        } catch {}
        XCTAssertTrue(exists(state.leftover), "The conversation is kept as it was")
        XCTAssertFalse(exists(storage.appendingPathComponent("\(second).json")))

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: archived.path)
        _ = try await state.sessions.handle(.clear(session: state.id, archive: second, expectedRevision: state.revision))
        XCTAssertFalse(exists(state.leftover))
    }

    /// A store whose folder can't be listed fails to open, and leaves no deletion running
    /// after it failed, when another runtime may own the store.
    func testAStoreThatCannotBeListedStartsNoDeletion() async throws {
        try skipAsRoot()
        let root = try root(), expired = try await expiredConversation(in: root)
        let record = root.appendingPathComponent("removing/\(expired.session).json")
        try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: expired.record, to: record)
        try restrict(root, to: 0o300)

        let writer = DispatchQueue(label: "held writer")
        writer.suspend()
        XCTAssertThrowsError(try AgentSessions(root: root, projectDirectory: { _ in root.path }, writer: writer,
                                               factory: { _, _, _, callback in FakeAgentRuntime(callback) }))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        writer.resume()
        writer.sync {}
        XCTAssertTrue(exists(expired.outputs.appendingPathComponent("tool.txt")), "Nothing was deleted")
        XCTAssertTrue(exists(record))
    }

    /// A pending baseline an interrupted clear left with the conversation is the archive's
    /// even after the archive finished it into a record under another name.
    func testAPendingBaselineTheArchiveFinishedIsStillTheArchives() async throws {
        let root = try root(), repo = try GitTestRepo(commit: true), expired = try await expiredConversation(in: root)
        let archive = SessionId()
        try markCleared(expired.record, into: archive)
        let record = try checkpoint(in: repo), turn = UUID().uuidString
        _ = try save(record, as: turn, for: archive, in: root)
        let folder = root.appendingPathComponent("checkpoints/\(expired.session)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(AgentCheckpointPending(turnID: turn, before: record.before))
            .write(to: folder.appendingPathComponent("pending-\(turn).json"))

        try restart(root)
        XCTAssertTrue(pins(record.before, in: repo), "The archive's baseline keeps its ref")
        XCTAssertTrue(pins(record.after, in: repo))
        XCTAssertFalse(exists(folder))
        XCTAssertFalse(exists(root.appendingPathComponent("removing/\(expired.session).json")))
    }

    /// An archive record that can't be decoded may pin the refs a deleted conversation's
    /// records name: they stay, and so does the deletion's record.
    func testAnArchiveRecordThatCannotBeDecodedLeavesOwnershipUnknown() async throws {
        let root = try root(), repo = try GitTestRepo(commit: true), expired = try await expiredConversation(in: root)
        let archive = SessionId()
        try markCleared(expired.record, into: archive)
        let shared = try checkpoint(in: repo), turn = UUID().uuidString
        _ = try save(shared, as: turn, for: expired.session, in: root)
        let damaged = try save(shared, as: turn, for: archive, in: root)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: damaged)) as? [String: Any])
        var before = try XCTUnwrap(json["before"] as? [String: Any])
        before["directory"] = 42
        json["before"] = before
        try JSONSerialization.data(withJSONObject: json).write(to: damaged)

        try restart(root)
        XCTAssertTrue(pins(shared.before, in: repo))
        XCTAssertTrue(pins(shared.after, in: repo))
        XCTAssertTrue(exists(root.appendingPathComponent("removing/\(expired.session).json")), "The deletion waits")
    }

    /// While the checkpoints folder can't be searched, a clear can't tell an earlier clear's
    /// leftovers from the conversation's own, so it waits.
    func testAClearWaitsWhileTheCheckpointsFolderCannotBeSearched() async throws {
        try skipAsRoot()
        let storage = try root(), repo = try GitTestRepo(commit: false)
        let state = try await clearedWithLeftover(storage, repo: repo)
        defer { state.sessions.shutdown() }
        let checkpoints = storage.appendingPathComponent("checkpoints", isDirectory: true)
        try restrict(checkpoints, to: 0o000)
        let second = SessionId()
        do {
            _ = try await state.sessions.handle(.clear(session: state.id, archive: second, expectedRevision: state.revision))
            XCTFail("The clear must wait")
        } catch {}
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: checkpoints.path)
        XCTAssertTrue(exists(state.leftover))
        XCTAssertFalse(exists(storage.appendingPathComponent("\(second).json")))
    }

    /// An archive's checkpoints are copies another conversation's leftovers point to by its
    /// name alone, so it is never cleared itself.
    func testAnArchiveCannotBeCleared() async throws {
        let storage = try root(), repo = try GitTestRepo(commit: false)
        let state = try await clearedWithLeftover(storage, repo: repo)
        defer { state.sessions.shutdown() }
        let archive = try await state.sessions.handle(.read(session: state.first))
        do {
            _ = try await state.sessions.handle(.clear(session: state.first, archive: SessionId(), expectedRevision: archive.revision))
            XCTFail("An archive can't be cleared")
        } catch {}
        XCTAssertTrue(exists(storage.appendingPathComponent("checkpoints/\(state.first)")))
    }

    /// Records from before snapshots kept their repository gain it at the next start, while
    /// their folder still leads there.
    func testOlderCheckpointRecordsGainTheirRepository() async throws {
        let storage = try root(), repo = try GitTestRepo(commit: false)
        try repo.write("file.txt", "before\n")
        try repo.commit("initial")
        let directory = repo.path
        let sessions = try AgentSessions(root: storage, projectDirectory: { _ in directory }, factory: { _, _, _, callback in
            SkillCaptureRuntime(callback) { try "after\n".write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8) }
        })
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: id, text: "Change this file", model: nil))
        let done = try await waitForQueue(sessions, id) { $0.status == .idle && $0.turns?.first?.checkpoint != nil }
        sessions.shutdown()
        let file = storage.appendingPathComponent("checkpoints/\(id)/\(try XCTUnwrap(done.turns?.first?.checkpoint?.id)).json")
        // As a version before snapshots kept their repository wrote it.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        for key in ["before", "after"] {
            var snapshot = try XCTUnwrap(json[key] as? [String: Any])
            snapshot.removeValue(forKey: "repository")
            json[key] = snapshot
        }
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("repository"))

        try restart(storage)
        let upgraded = try JSONDecoder().decode(AgentCheckpointRecord.self, from: Data(contentsOf: file))
        let common = try repo.run("rev-parse", "--path-format=absolute", "--git-common-dir").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(upgraded.before.repository, common)
        XCTAssertEqual(upgraded.after.repository, common)
    }

    /// A Git whose `write-tree` waits for `gate` from its `from`th run on, so a checkpoint
    /// stays being taken until the test lets it finish; `count` tells how many began.
    private func gatedGit(_ tools: URL, from: Int) throws -> (git: GitCommand, gate: URL, count: () -> Int) {
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let gate = tools.appendingPathComponent("gate"), count = tools.appendingPathComponent("count")
        let git = try AgentCheckpointTests.git("""
            for a in "$@"; do
              if [ "$a" = write-tree ]; then
                n=$(($(cat '\(count.path)' 2>/dev/null || echo 0) + 1)); echo $n > '\(count.path)'
                if [ $n -ge \(from) ]; then while [ ! -f '\(gate.path)' ]; do sleep 0.05; done; fi
              fi
            done
            """, in: tools)
        return (git, gate, { Int(((try? String(contentsOf: count, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 })
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A checkpoint still being taken when the store shuts down finishes first: it makes a
    /// ref and a record the store's next owner must find whole.
    func testShutdownWaitsForACheckpointBeingTaken() async throws {
        let root = try root(), repo = try GitTestRepo(commit: true)
        let gated = try gatedGit(root.appendingPathComponent("tools"), from: 2)
        let session = SessionId(), writer = DispatchQueue(label: "writer")
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in repo.path }, writer: writer,
                                         checkpoints: AgentCheckpointStore(git: gated.git), factory: { _, _, _, callback in FakeAgentRuntime(callback) })
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: session, text: "Work", model: nil))
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { sessions.shutdown(); stopped.signal() }
        // Shutting down ends the turn, whose checkpoint is then taken.
        try await waitUntil { gated.count() >= 2 }
        // Nothing else holds shutdown up: what it queued is written.
        sessions.publishActivity()
        writer.sync {}
        XCTAssertEqual(stopped.wait(timeout: .now() + 0.3), .timedOut, "Shutdown waits for the checkpoint being taken")
        try Data().write(to: gated.gate)
        XCTAssertEqual(stopped.wait(timeout: .now() + 10), .success)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("checkpoints/\(session)").path)) ?? []
        XCTAssertTrue(files.contains { !$0.hasPrefix("pending-") && $0.hasSuffix(".json") }, "\(files)")
    }

    /// A store whose last turn ended while its checkpoint was still being taken: the
    /// baseline kept as a version before snapshots kept their repository wrote it, and no
    /// record yet, so opening the store takes the checkpoint again.
    private func unfinishedCheckpoint(_ storage: URL, repo: GitTestRepo) async throws -> (session: SessionId, record: URL, before: AgentCheckpointStore.Snapshot) {
        try repo.write("file.txt", "before\n")
        try repo.commit("initial")
        let directory = repo.path
        let sessions = try AgentSessions(root: storage, projectDirectory: { _ in directory }, factory: { _, _, _, callback in
            SkillCaptureRuntime(callback) { try "after\n".write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8) }
        })
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: id, text: "Change this file", model: nil))
        let done = try await waitForQueue(sessions, id) { $0.status == .idle && $0.turns?.first?.checkpoint != nil }
        sessions.shutdown()
        let turn = try XCTUnwrap(done.turns?.first?.checkpoint?.id)
        let folder = storage.appendingPathComponent("checkpoints/\(id)", isDirectory: true)
        let record = folder.appendingPathComponent(turn + ".json")
        let finished = try JSONDecoder().decode(AgentCheckpointRecord.self, from: Data(contentsOf: record))
        try FileManager.default.removeItem(at: record)
        var before = finished.before
        before.repository = nil
        try JSONEncoder().encode(AgentCheckpointPending(turnID: turn, before: before)).write(to: folder.appendingPathComponent("pending-\(turn).json"))
        let saved = storage.appendingPathComponent("\(id).json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: saved)) as? [String: Any])
        var snapshot = try XCTUnwrap(json["snapshot"] as? [String: Any])
        var turns = try XCTUnwrap(snapshot["turns"] as? [[String: Any]])
        turns[0].removeValue(forKey: "checkpoint")
        snapshot["turns"] = turns
        json["snapshot"] = snapshot
        try JSONSerialization.data(withJSONObject: json).write(to: saved)
        return (id, record, finished.before)
    }

    /// The record a recovered checkpoint gets names the repository even when its baseline,
    /// read before older records were upgraded, didn't.
    func testARecoveredCheckpointKeepsItsRepository() async throws {
        let storage = try root().appendingPathComponent("agents"), repo = try GitTestRepo(commit: false)
        let unfinished = try await unfinishedCheckpoint(storage, repo: repo)
        let gated = try gatedGit(storage.deletingLastPathComponent().appendingPathComponent("tools"), from: 1)
        let writer = DispatchQueue(label: "held writer")
        writer.suspend()
        let sessions = try AgentSessions(root: storage, projectDirectory: { _ in repo.path }, writer: writer,
                                         checkpoints: AgentCheckpointStore(git: gated.git), factory: { _, _, _, callback in FakeAgentRuntime(callback) })
        // Older records are upgraded while the checkpoint is still being taken.
        try await waitUntil { gated.count() >= 1 }
        writer.resume()
        writer.sync {}
        try Data().write(to: gated.gate)
        try await waitUntil { FileManager.default.fileExists(atPath: unfinished.record.path) }
        sessions.shutdown()
        let record = try JSONDecoder().decode(AgentCheckpointRecord.self, from: Data(contentsOf: unfinished.record))
        XCTAssertEqual(record.before.reference, unfinished.before.reference)
        XCTAssertEqual(record.before.repository, unfinished.before.repository)
    }

    /// A checkpoint still being taken when shutdown gives up waiting keeps the store held
    /// until it is written, so no other runtime opens the store meanwhile.
    func testTheStoreStaysHeldUntilACheckpointOutlastingShutdownIsWritten() async throws {
        let root = try root(), storage = root.appendingPathComponent("agents"), repo = try GitTestRepo(commit: false)
        let unfinished = try await unfinishedCheckpoint(storage, repo: repo)
        let gated = try gatedGit(root.appendingPathComponent("tools"), from: 1)
        let service = try AgentRuntimeService(storageDirectory: storage, home: root, checkpoints: AgentCheckpointStore(git: gated.git),
                                              projectDirectory: { _ in URL(fileURLWithPath: repo.path) })
        service.checkpointDrain = 0.2
        try await waitUntil { gated.count() >= 1 }
        await Task.detached { service.shutdown() }.value
        let lock = storage.appendingPathComponent("runtime.lock")
        XCTAssertThrowsError(try FileLock.tryLock(lock), "The store stays held") { XCTAssertEqual($0 as? FileLock.Failure, .held) }

        try Data().write(to: gated.gate)
        var reopened: FileLock?
        let deadline = Date().addingTimeInterval(10)
        while reopened == nil, Date() < deadline {
            reopened = try? FileLock.tryLock(lock)
            if reopened == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertNotNil(reopened, "Released once the checkpoint was written")
        reopened?.unlock()
        XCTAssertTrue(FileManager.default.fileExists(atPath: unfinished.record.path))
    }

    /// A store shut down with its default wait releases nothing before a checkpoint being
    /// taken is written, however long that takes, so the host may let another runtime in
    /// as soon as it returns: even a store the host owns, which the runtime couldn't lock.
    func testShutdownReturnsOnlyOnceACheckpointIsWritten() async throws {
        let root = try root(), storage = root.appendingPathComponent("agents"), repo = try GitTestRepo(commit: false)
        let unfinished = try await unfinishedCheckpoint(storage, repo: repo)
        let gated = try gatedGit(root.appendingPathComponent("tools"), from: 1)
        // Nothing of the runtime's own holds this store: only shutdown's wait keeps it.
        try FileManager.default.createDirectory(at: storage.appendingPathComponent("runtime.lock"), withIntermediateDirectories: true)
        let service = try AgentRuntimeService(storageDirectory: storage, home: root, hostOwnsStore: true,
                                              checkpoints: AgentCheckpointStore(git: gated.git),
                                              projectDirectory: { _ in URL(fileURLWithPath: repo.path) })
        XCTAssertNil(service.checkpointDrain, "Shutdown waits however long checkpoints take")
        try await waitUntil { gated.count() >= 1 }
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { service.shutdown(); stopped.signal() }
        XCTAssertEqual(stopped.wait(timeout: .now() + 0.5), .timedOut)
        try Data().write(to: gated.gate)
        XCTAssertEqual(stopped.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unfinished.record.path), "Written before shutdown returned")
    }

    /// Shutdown called from every Swift task worker at once, as a host closing workspaces
    /// from a task group may, still returns: the checkpoint it waits for needs no worker.
    func testShutdownFinishesACheckpointWhileEveryTaskWorkerIsBlocked() async throws {
        let root = try root(), repo = try GitTestRepo(commit: true)
        let gated = try gatedGit(root.appendingPathComponent("tools"), from: 2)
        let session = SessionId()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in repo.path },
                                         checkpoints: AgentCheckpointStore(git: gated.git), factory: { _, _, _, callback in FakeAgentRuntime(callback) })
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: session, text: "Work", model: nil))
        let began = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
        Task.detached { began.signal(); sessions.shutdown(); stopped.signal() }
        XCTAssertEqual(began.wait(timeout: .now() + 10), .success)
        // Shutting down ends the turn, whose checkpoint is then taken.
        try await waitUntil { gated.count() >= 2 }
        let result = try TaskWorkers().whileBlocked {
            try Data().write(to: gated.gate)
            return stopped.wait(timeout: .now() + 10)
        }
        XCTAssertEqual(result, .success, "Shutdown returns without a free task worker")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("checkpoints/\(session)").path)) ?? []
        XCTAssertTrue(files.contains { !$0.hasPrefix("pending-") && $0.hasSuffix(".json") }, "\(files)")
    }

    /// A revert under way when the store shuts down is applied and recorded first, without
    /// a free Swift task worker; one asked for after is refused and changes nothing.
    func testShutdownFinishesARevertUnderWayAndRefusesLaterOnes() async throws {
        let root = try root(), repo = try GitTestRepo(commit: false)
        try repo.write("file.txt", "before\n")
        try repo.commit("initial")
        let directory = repo.path, tools = root.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let began = tools.appendingPathComponent("began"), gate = tools.appendingPathComponent("gate")
        // Restoring a file waits for `gate`; nothing else reads blobs.
        let git = try AgentCheckpointTests.git("""
            for a in "$@"; do
              if [ "$a" = cat-file ]; then touch '\(began.path)'; while [ ! -f '\(gate.path)' ]; do sleep 0.05; done; fi
            done
            """, in: tools)
        let writer = DispatchQueue(label: "writer"), runtimeStopped = DispatchSemaphore(value: 0)
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in directory }, writer: writer,
                                         checkpoints: AgentCheckpointStore(git: git), factory: { _, _, _, callback in
            SkillCaptureRuntime(callback, onSend: { try "after\n".write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8) },
                                onStop: { runtimeStopped.signal() })
        })
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: id, text: "Change this file", model: nil))
        let done = try await waitForQueue(sessions, id) { $0.status == .idle && $0.turns?.first?.checkpoint != nil }
        let checkpoint = try XCTUnwrap(done.turns?.first?.checkpoint?.id)
        let revert = Task { try await sessions.conversation(.revert(session: id, checkpoint: checkpoint, paths: nil, force: true)) }
        try await waitUntil { FileManager.default.fileExists(atPath: began.path) }

        let shutdownBegan = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
        Task.detached { shutdownBegan.signal(); sessions.shutdown(); stopped.signal() }
        XCTAssertEqual(shutdownBegan.wait(timeout: .now() + 10), .success)
        // Shutdown has saved every conversation and stops their providers: what it queued is written.
        XCTAssertEqual(runtimeStopped.wait(timeout: .now() + 10), .success)
        writer.sync {}
        let result = try TaskWorkers().whileBlocked {
            XCTAssertEqual(stopped.wait(timeout: .now() + 0.3), .timedOut, "Shutdown waits for the revert under way")
            try Data().write(to: gate)
            return stopped.wait(timeout: .now() + 10)
        }
        XCTAssertEqual(result, .success, "Shutdown returns without a free task worker")
        let saved = try String(contentsOf: root.appendingPathComponent("\(id).json"), encoding: .utf8)
        XCTAssertTrue(saved.contains("Reverted 1 file to before a turn."), "Recorded before shutdown returned")
        guard case .revert(let reply) = try await revert.value else { return XCTFail("Unexpected reply") }
        XCTAssertEqual(reply.reverted, ["file.txt"])
        XCTAssertEqual(try String(contentsOfFile: directory + "/file.txt", encoding: .utf8), "before\n")

        try "edited later\n".write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8)
        do {
            _ = try await sessions.conversation(.revert(session: id, checkpoint: checkpoint, paths: nil, force: true))
            XCTFail("A revert after shutdown is refused")
        } catch {}
        XCTAssertEqual(try String(contentsOfFile: directory + "/file.txt", encoding: .utf8), "edited later\n")
    }

    /// A conversation closed after shutdown stays as shutdown saved it: the store may
    /// already be another runtime's.
    func testClosingAfterShutdownWritesNothing() async throws {
        let root = try root(), writer = DispatchQueue(label: "writer")
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, writer: writer,
                                         factory: { _, _, _, callback in FakeAgentRuntime(callback) })
        let id = SessionId(), project = ProjectId()
        _ = try await sessions.handle(.create(session: id, project: project, provider: .claude))
        sessions.shutdown()
        let file = root.appendingPathComponent("\(id).json")
        let saved = try Data(contentsOf: file)
        _ = try await sessions.handle(.close(session: id))
        sessions.close(project: project)
        writer.sync {}
        XCTAssertEqual(try Data(contentsOf: file), saved)
    }

    /// A checkpoint ref Git may or may not have made, and couldn't say, is kept track of
    /// and removed when the store next opens, rather than pinning its files for good: a
    /// turn's baseline as well as its final state.
    func testARefACaptureLeftUnsettledIsRemovedAtTheNextStart() async throws {
        for unsettledFrom in [1, 2] {
            let root = try root(), repo = try GitTestRepo(commit: true)
            let tools = root.appendingPathComponent("tools"), made = tools.appendingPathComponent("made")
            try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
            // From its `unsettledFrom`th, makes checkpoint refs without reporting it, and can
            // neither find nor remove them.
            let git = try AgentCheckpointTests.git("""
                case " $* " in
                  *" show-ref --exists "*) head -c 5000000 /dev/zero; exit 0 ;;
                  *" update-ref --no-deref -d "*) exit 1 ;;
                  *" update-ref refs/tab/checkpoints/"*)
                    n=$(($(cat '\(made.path)' 2>/dev/null || echo 0) + 1)); echo $n > '\(made.path)'
                    if [ $n -ge \(unsettledFrom) ]; then /usr/bin/git "$@"; head -c 5000000 /dev/zero; exit 0; fi ;;
                esac
                """, in: tools)
            let id = SessionId()
            let sessions = try AgentSessions(root: root, projectDirectory: { _ in repo.path }, checkpoints: AgentCheckpointStore(git: git),
                                             factory: { _, _, _, callback in SkillCaptureRuntime(callback) })
            _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
            _ = try await sessions.handle(.send(session: id, text: "Work", model: nil))
            _ = try await waitForQueue(sessions, id) { $0.status == .idle && $0.turns?.first?.completedAt != nil }
            sessions.shutdown()
            let done = try await sessions.handle(.read(session: id))
            XCTAssertNil(done.turns?.first?.checkpoint, "No checkpoint stands on a ref that may not be there")
            let unsettled = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("checkpoints/.unsettled"),
                                                                        includingPropertiesForKeys: nil)
            XCTAssertEqual(unsettled.count, 1, "\(unsettledFrom)")
            let snapshot = try JSONDecoder().decode(AgentCheckpointStore.Snapshot.self, from: Data(contentsOf: try XCTUnwrap(unsettled.first)))
            XCTAssertNoThrow(try repo.run("rev-parse", "--verify", snapshot.reference), "Git made it")

            try restart(root)
            XCTAssertThrowsError(try repo.run("rev-parse", "--verify", "--quiet", snapshot.reference), "Removed at the next start")
            XCTAssertFalse(exists(try XCTUnwrap(unsettled.first)))
        }
    }

    /// A checkpoint ref the turn couldn't use, and Git couldn't remove then, is removed
    /// when the store next opens: a baseline whose record couldn't be saved, and a final
    /// state whose changes couldn't be read.
    func testARefATurnCouldntUseIsRemovedAtTheNextStart() async throws {
        for baselineUnsaved in [true, false] {
            let root = try root(), repo = try GitTestRepo(commit: true)
            let tools = root.appendingPathComponent("tools")
            try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
            // Can neither remove a checkpoint ref nor read a turn's changes.
            let git = try AgentCheckpointTests.git("""
                case " $* " in
                  *" update-ref --no-deref -d "*) exit 1 ;;
                  *" diff --numstat "*) exit 1 ;;
                esac
                """, in: tools)
            let id = SessionId(), blocked = root.appendingPathComponent("checkpoints/\(id)")
            if baselineUnsaved {
                // Where its baseline's record would go is taken.
                try FileManager.default.createDirectory(at: blocked.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: blocked)
            }
            let sessions = try AgentSessions(root: root, projectDirectory: { _ in repo.path }, checkpoints: AgentCheckpointStore(git: git),
                                             factory: { _, _, _, callback in SkillCaptureRuntime(callback) })
            _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
            _ = try await sessions.handle(.send(session: id, text: "Work", model: nil))
            _ = try await waitForQueue(sessions, id) { $0.status == .idle && $0.turns?.first?.completedAt != nil }
            sessions.shutdown()
            let kept = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("checkpoints/.unsettled"),
                                                                   includingPropertiesForKeys: nil)
            XCTAssertEqual(kept.count, 1, "\(baselineUnsaved)")
            let snapshot = try JSONDecoder().decode(AgentCheckpointStore.Snapshot.self, from: Data(contentsOf: try XCTUnwrap(kept.first)))
            XCTAssertNoThrow(try repo.run("rev-parse", "--verify", snapshot.reference), "Git couldn't remove it")
            if baselineUnsaved { try FileManager.default.removeItem(at: blocked) }

            try restart(root)
            XCTAssertThrowsError(try repo.run("rev-parse", "--verify", "--quiet", snapshot.reference), "Removed at the next start")
            XCTAssertFalse(exists(try XCTUnwrap(kept.first)))
        }
    }

    /// A revert runs in turn with what else changes the conversation's files: a turn
    /// asked for while it is applied starts after it, so the revert never undoes the
    /// turn's work, and a clear asked for meanwhile waits for it too.
    func testARevertRunsInTurnWithTurnsAndClears() async throws {
        let root = try root(), repo = try GitTestRepo(commit: false)
        try repo.write("file.txt", "before\n")
        try repo.commit("initial")
        let directory = repo.path, tools = root.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let began = tools.appendingPathComponent("began"), gate = tools.appendingPathComponent("gate")
        // Restoring a file waits for `gate`; nothing else reads blobs.
        let git = try AgentCheckpointTests.git("""
            for a in "$@"; do
              if [ "$a" = cat-file ]; then touch '\(began.path)'; while [ ! -f '\(gate.path)' ]; do sleep 0.05; done; fi
            done
            """, in: tools)
        let turns = TurnCounter()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in directory }, checkpoints: AgentCheckpointStore(git: git),
                                         factory: { _, _, _, callback in
            SkillCaptureRuntime(callback, onSend: {
                try "turn \(turns.next())\n".write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8)
            })
        })
        defer { sessions.shutdown() }
        defer { try? Data().write(to: gate) }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: id, text: "Change this file", model: nil))
        let done = try await waitForQueue(sessions, id) { $0.status == .idle && $0.turns?.first?.checkpoint != nil }
        let checkpoint = try XCTUnwrap(done.turns?.first?.checkpoint?.id)

        let revert = Task { try await sessions.conversation(.revert(session: id, checkpoint: checkpoint, paths: nil, force: true)) }
        try await waitUntil { FileManager.default.fileExists(atPath: began.path) }
        let next = Task { try await sessions.handle(.send(session: id, text: "Change it again", model: nil)) }
        // Admitted, its checkpoint queued behind the revert.
        _ = try await waitForQueue(sessions, id) { $0.turns?.count == 2 }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(turns.count, 1, "The next turn waits for the revert")
        try Data().write(to: gate)
        guard case .revert(let reply) = try await revert.value else { return XCTFail("Unexpected reply") }
        XCTAssertEqual(reply.reverted, ["file.txt"])
        _ = try await next.value
        let again = try await waitForQueue(sessions, id) { $0.status == .idle && $0.turns?.count == 2 && $0.turns?.last?.checkpoint != nil }
        XCTAssertEqual(try String(contentsOfFile: directory + "/file.txt", encoding: .utf8), "turn 2\n", "The later turn's work stays")

        try FileManager.default.removeItem(at: began)
        try FileManager.default.removeItem(at: gate)
        let second = Task { try await sessions.conversation(.revert(session: id, checkpoint: checkpoint, paths: nil, force: true)) }
        try await waitUntil { FileManager.default.fileExists(atPath: began.path) }
        let waiting = DispatchSemaphore(value: 0), waited = CompletionFlag()
        sessions.clearStep = { step in if step == .waiting { waiting.signal() } else { waited.set() } }
        let clearing = Task { try await sessions.handle(.clear(session: id, archive: SessionId(), expectedRevision: again.revision)) }
        XCTAssertEqual(waiting.wait(timeout: .now() + 10), .success, "The clear waits for the conversation's checkpoints")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(waited.isSet, "A clear waits for the revert being applied")
        try Data().write(to: gate)
        _ = try await second.value
        // The revert's notice changed the conversation the clear was asked for.
        do {
            _ = try await clearing.value
            XCTFail("The clear sees the conversation the revert changed")
        } catch {
            XCTAssertEqual((error as? AgentRuntimeError)?.message, "The conversation changed. Review it before clearing.")
        }
        let after = try await sessions.handle(.read(session: id))
        XCTAssertTrue(after.items.contains { $0.text == "Reverted 1 file to before a turn." && $0.kind == .notice })
    }

    /// No revert is admitted while an agent works, in the foreground or the background: it
    /// may be changing the same files.
    func testARevertIsRefusedWhileTheAgentWorks() async throws {
        let root = try root(), repo = try GitTestRepo(commit: false)
        try repo.write("file.txt", "before\n")
        try repo.commit("initial")
        let directory = repo.path, turns = TurnCounter(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in directory }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = {
                // The first turn ends; later ones keep working.
                guard turns.next() == 1 else { return }
                try "after\n".write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8)
                callback(.status(.idle))
            }
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: id, text: "Change this file", model: nil))
        let done = try await waitForQueue(sessions, id) { $0.status == .idle && $0.turns?.first?.checkpoint != nil }
        let checkpoint = try XCTUnwrap(done.turns?.first?.checkpoint?.id)
        func assertRefused(_ reason: String) async {
            do {
                _ = try await sessions.conversation(.revert(session: id, checkpoint: checkpoint, paths: nil, force: true))
                XCTFail("Refused while \(reason)")
            } catch {
                XCTAssertEqual((error as? ServiceError)?.message, "Stop active work before reverting.", reason)
            }
            XCTAssertEqual(try? String(contentsOfFile: directory + "/file.txt", encoding: .utf8), "after\n", reason)
        }

        // The turn ended, but an agent it started works on in the background.
        box.runtime?.callback(.subagents([AgentSubagent(id: "a1", toolUseID: "task", description: "Edit in the background", background: true)]))
        _ = try await waitForQueue(sessions, id) { $0.subagents?.first?.status == .running }
        await assertRefused("a background agent works")
        box.runtime?.callback(.subagents([AgentSubagent(id: "a1", toolUseID: "task", description: "Edit in the background",
                                                        background: true, status: .completed)]))
        _ = try await waitForQueue(sessions, id) { $0.subagents?.first?.status == .completed }

        _ = try await sessions.handle(.send(session: id, text: "Keep working", model: nil))
        _ = try await waitForQueue(sessions, id) { $0.status == .working }
        await assertRefused("the agent works")
    }

    /// A message's files are written when it is admitted, so a clear asked for after it
    /// was stopped, before its turn could start, archives them whole.
    func testAStoppedMessagesFilesAreArchivedWhole() async throws {
        let root = try root(), gate = root.appendingPathComponent("gate")
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            // The provider takes its first settings slowly, holding the turn before it starts.
            runtime.onAccess = { _ in
                while !FileManager.default.fileExists(atPath: gate.path) { try await Task.sleep(for: .milliseconds(20)) }
            }
            return runtime
        })
        defer { sessions.shutdown() }
        defer { try? Data().write(to: gate) }
        let id = SessionId(), archive = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        let notes = AgentChatAttachment(id: "notes", name: "notes.txt", mimeType: "text/plain", data: Data("Notes".utf8))
        let sending = Task { try await sessions.handle(.send(session: id, text: "Read this", model: nil, attachments: [notes])) }
        let admitted = try await waitForQueue(sessions, id) { $0.items.contains { $0.kind == .user && $0.attachments?.isEmpty == false } }
        let item = try XCTUnwrap(admitted.items.first { $0.kind == .user }?.id)
        _ = try await sessions.handle(.interrupt(session: id))
        // Once the turn's file changes are known, here that the folder isn't in Git.
        let stopped = try await waitForQueue(sessions, id) { $0.status == .idle && $0.turns?.first?.checkpointStatus?.state == .untracked }
        _ = try await sessions.handle(.clear(session: id, archive: archive, expectedRevision: stopped.revision))
        try Data().write(to: gate)
        _ = try? await sending.value
        let kept = try await sessions.attachment(AgentAttachmentRequest(session: archive, item: item, attachment: "notes"))
        XCTAssertEqual(kept.attachment.data, Data("Notes".utf8))
    }

    /// A revert admitted before a message is queued before the message's checkpoint, so
    /// the message's turn starts after the revert, however the two interleave.
    func testARevertAdmittedBeforeAMessageIsAppliedFirst() async throws {
        let root = try root(), repo = try GitTestRepo(commit: false)
        try repo.write("file.txt", "before\n")
        try repo.commit("initial")
        let directory = repo.path, tools = root.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let began = tools.appendingPathComponent("began"), gate = tools.appendingPathComponent("gate")
        let count = tools.appendingPathComponent("count")
        // Restoring a file waits for `gate`; nothing else reads blobs. Each checkpoint taken is counted.
        let git = try AgentCheckpointTests.git("""
            for a in "$@"; do
              if [ "$a" = write-tree ]; then n=$(($(cat '\(count.path)' 2>/dev/null || echo 0) + 1)); echo $n > '\(count.path)'; fi
              if [ "$a" = cat-file ]; then touch '\(began.path)'; while [ ! -f '\(gate.path)' ]; do sleep 0.05; done; fi
            done
            """, in: tools)
        func checkpointsTaken() -> Int {
            Int(((try? String(contentsOf: count, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        let turns = TurnCounter()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in directory }, checkpoints: AgentCheckpointStore(git: git),
                                         factory: { _, _, _, callback in
            SkillCaptureRuntime(callback, onSend: {
                try "turn \(turns.next())\n".write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8)
            })
        })
        let admitted = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        defer { sessions.shutdown() }
        defer { proceed.signal(); try? Data().write(to: gate) }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: id, text: "Change this file", model: nil))
        let done = try await waitForQueue(sessions, id) { $0.status == .idle && $0.turns?.first?.checkpoint != nil }
        let checkpoint = try XCTUnwrap(done.turns?.first?.checkpoint?.id)

        let held = CompletionFlag()
        sessions.revertAdmitted = { [weak sessions] in
            // Admitted and queued in one step on the sessions queue: nothing is admitted between.
            if sessions?.onSessionsQueue == true { held.set() }
            admitted.signal(); proceed.wait()
        }
        let revert = Task { try await sessions.conversation(.revert(session: id, checkpoint: checkpoint, paths: nil, force: true)) }
        XCTAssertEqual(admitted.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(held.isSet, "Held between admission and queueing on the sessions queue")
        // Asked for while the revert is admitted but not yet queued: were the message admitted
        // meanwhile, its checkpoint would be taken before the revert is queued at all.
        let taken = checkpointsTaken()
        let next = Task { try await sessions.handle(.send(session: id, text: "Change it again", model: nil)) }
        for _ in 0..<50 where checkpointsTaken() == taken { try await Task.sleep(for: .milliseconds(20)) }
        proceed.signal()
        try await waitUntil { FileManager.default.fileExists(atPath: began.path) }
        _ = try await waitForQueue(sessions, id) { $0.turns?.count == 2 }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(turns.count, 1, "The message's turn waits for the revert")
        try Data().write(to: gate)
        guard case .revert(let reply) = try await revert.value else { return XCTFail("Unexpected reply") }
        XCTAssertEqual(reply.reverted, ["file.txt"])
        _ = try await next.value
        _ = try await waitForQueue(sessions, id) { $0.status == .idle && $0.turns?.count == 2 }
        XCTAssertEqual(try String(contentsOfFile: directory + "/file.txt", encoding: .utf8), "turn 2\n", "The later turn's work stays")
    }

    /// A conversation closed while its provider still stops takes no revert until it has:
    /// the provider may still change files.
    func testARevertWaitsForAClosedConversationsProviderToStop() async throws {
        let root = try root(), repo = try GitTestRepo(commit: false), gate = root.appendingPathComponent("gate")
        try repo.write("file.txt", "before\n")
        try repo.commit("initial")
        let directory = repo.path, stopping = DispatchSemaphore(value: 0)
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in directory }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.folder = AgentFolder(directory)
            runtime.onSend = {
                try "after\n".write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8)
                callback(.status(.idle))
            }
            runtime.onStop = {
                stopping.signal()
                while !FileManager.default.fileExists(atPath: gate.path) { Thread.sleep(forTimeInterval: 0.02) }
            }
            return runtime
        })
        defer { sessions.shutdown() }
        defer { try? Data().write(to: gate) }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: id, text: "Change this file", model: nil))
        let done = try await waitForQueue(sessions, id) { $0.status == .idle && $0.turns?.first?.checkpoint != nil }
        let checkpoint = try XCTUnwrap(done.turns?.first?.checkpoint?.id)
        _ = try await sessions.handle(.close(session: id))
        XCTAssertEqual(stopping.wait(timeout: .now() + 10), .success)
        do {
            _ = try await sessions.conversation(.revert(session: id, checkpoint: checkpoint, paths: nil, force: true))
            XCTFail("No revert while the provider stops")
        } catch {
            XCTAssertEqual((error as? AgentRuntimeError)?.message, "The agent is still stopping. Try again shortly.")
        }
        XCTAssertEqual(try String(contentsOfFile: directory + "/file.txt", encoding: .utf8), "after\n")
        // Cleared meanwhile, its archive keeps the checkpoint, which waits for the provider too.
        let closed = try await sessions.handle(.read(session: id))
        let archive = SessionId()
        _ = try await sessions.handle(.clear(session: id, archive: archive, expectedRevision: closed.revision))
        do {
            _ = try await sessions.conversation(.revert(session: archive, checkpoint: checkpoint, paths: nil, force: true))
            XCTFail("No revert from the archive while the provider stops")
        } catch {
            XCTAssertEqual((error as? AgentRuntimeError)?.message, "The agent is still stopping. Try again shortly.")
        }
        XCTAssertEqual(try String(contentsOfFile: directory + "/file.txt", encoding: .utf8), "after\n")
        try Data().write(to: gate)
        var reverted: AgentRevertReply?
        for _ in 0..<200 where reverted == nil {
            if case .revert(let reply)? = try? await sessions.conversation(.revert(session: archive, checkpoint: checkpoint, paths: nil, force: true)) {
                reverted = reply
            } else { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertEqual(reverted?.reverted, ["file.txt"], "Once it stopped")
    }

    /// A provider whose own replaced process still exits, as Claude's after a stop, takes
    /// no revert meanwhile either.
    func testARevertWaitsForAProcessTheProviderReplaced() async throws {
        let root = try root(), repo = try GitTestRepo(commit: false)
        try repo.write("file.txt", "before\n")
        try repo.commit("initial")
        let directory = repo.path, box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in directory }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.folder = AgentFolder(directory)
            runtime.onSend = {
                try "after\n".write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8)
                callback(.status(.idle))
            }
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: id, text: "Change this file", model: nil))
        let done = try await waitForQueue(sessions, id) { $0.status == .idle && $0.turns?.first?.checkpoint != nil }
        let checkpoint = try XCTUnwrap(done.turns?.first?.checkpoint?.id)
        let runtime = try XCTUnwrap(box.runtime)
        runtime.exiting = true
        do {
            _ = try await sessions.conversation(.revert(session: id, checkpoint: checkpoint, paths: nil, force: true))
            XCTFail("No revert while a replaced process exits")
        } catch {
            XCTAssertEqual((error as? AgentRuntimeError)?.message, "The agent is still stopping. Try again shortly.")
        }
        runtime.exiting = false
        guard case .revert(let reply) = try await sessions.conversation(.revert(session: id, checkpoint: checkpoint, paths: nil, force: true)) else {
            return XCTFail("Unexpected reply")
        }
        XCTAssertEqual(reply.reverted, ["file.txt"])
    }

    /// Another conversation's provider process still exiting in the same folder, however
    /// that folder is spelled, holds a revert there too: it may still change its files.
    func testARevertWaitsForAnyProcessStillExitingInItsFolder() async throws {
        let root = try root(), repo = try GitTestRepo(commit: false)
        try repo.write("file.txt", "before\n")
        try repo.commit("initial")
        let link = root.appendingPathComponent("linked-project")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: repo.path)
        let projectA = ProjectId(), projectB = ProjectId(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { $0 == projectA ? link.path : repo.path }, factory: { _, directory, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.folder = AgentFolder(directory)
            runtime.onSend = {
                try "after \(directory)\n".write(toFile: repo.path + "/file.txt", atomically: true, encoding: .utf8)
                callback(.status(.idle))
            }
            if directory == link.path { box.install(runtime) }
            return runtime
        })
        defer { sessions.shutdown() }
        let a = SessionId(), b = SessionId()
        _ = try await sessions.handle(.create(session: a, project: projectA, provider: .claude))
        _ = try await sessions.handle(.create(session: b, project: projectB, provider: .claude))
        _ = try await sessions.handle(.send(session: b, text: "Change this file", model: nil))
        let done = try await waitForQueue(sessions, b) { $0.status == .idle && $0.turns?.first?.checkpoint != nil }
        let checkpoint = try XCTUnwrap(done.turns?.first?.checkpoint?.id)
        _ = try await sessions.handle(.send(session: a, text: "Work here too", model: nil))
        _ = try await waitForQueue(sessions, a) { $0.status == .idle }
        let other = try XCTUnwrap(box.runtime)
        other.exiting = true
        do {
            _ = try await sessions.conversation(.revert(session: b, checkpoint: checkpoint, paths: nil, force: true))
            XCTFail("No revert while another conversation's process exits in the folder")
        } catch {
            XCTAssertEqual((error as? AgentRuntimeError)?.message, "The agent is still stopping. Try again shortly.")
        }
        other.exiting = false
        guard case .revert(let reply) = try await sessions.conversation(.revert(session: b, checkpoint: checkpoint, paths: nil, force: true)) else {
            return XCTFail("Unexpected reply")
        }
        XCTAssertEqual(reply.reverted, ["file.txt"])
    }

    /// The host's callbacks run off the conversations' queue, in order, so one may call back
    /// into them, even to shut them down.
    func testCallbacksMayCallBackIntoTheConversations() async throws {
        let root = try root()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = { callback(.status(.idle)) }
            return runtime
        })
        defer { sessions.shutdown() }
        let changed = CompletionFlag(), armed = CompletionFlag(), stopped = CompletionFlag()
        sessions.activityChanged = { [weak sessions] _, _ in
            guard let sessions else { return }
            guard !sessions.onSessionsQueue else { return XCTFail("Called on the conversations' queue") }
            _ = sessions.hasSessions
            guard armed.isSet, !stopped.isSet else { return }
            sessions.shutdown()
            stopped.set()
        }
        sessions.changed = { [weak sessions] _, _ in
            guard let sessions else { return }
            guard !sessions.onSessionsQueue else { return XCTFail("Called on the conversations' queue") }
            _ = sessions.hasSessions
            changed.set()
        }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: id, text: "Hello", model: nil))
        for _ in 0..<500 where !changed.isSet { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(changed.isSet)
        armed.set()
        sessions.publishActivity()
        XCTAssertTrue(stopped.isSet, "Shut down from its own callback")
    }

    /// Publishing activity returns only once the callbacks it queued have run.
    func testPublishingActivityWaitsForItsCallbacks() async throws {
        let root = try root()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in FakeAgentRuntime(callback) })
        defer { sessions.shutdown() }
        _ = try await sessions.handle(.create(session: SessionId(), project: ProjectId(), provider: .claude))
        let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), holding = CompletionFlag()
        sessions.activityChanged = { _, _ in
            guard !holding.isSet else { return }
            holding.set()
            held.signal()
            release.wait()
        }
        let published = CompletionFlag(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            sessions.publishActivity()
            published.set()
            done.signal()
        }
        defer { release.signal(); XCTAssertEqual(done.wait(timeout: .now() + 10), .success) }
        XCTAssertEqual(held.wait(timeout: .now() + 10), .success)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(published.isSet, "Returned while its callback still ran")
    }

    /// Shutdown returns once the callbacks already queued have run, so none runs after it.
    func testShutdownWaitsForTheCallbacksAlreadyQueued() async throws {
        let root = try root()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in FakeAgentRuntime(callback) })
        let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), holding = CompletionFlag()
        sessions.changed = { _, _ in
            guard !holding.isSet else { return }
            holding.set()
            held.signal()
            release.wait()
        }
        _ = try await sessions.handle(.create(session: SessionId(), project: ProjectId(), provider: .claude))
        XCTAssertEqual(held.wait(timeout: .now() + 10), .success)
        let returned = CompletionFlag(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            sessions.shutdown()
            returned.set()
            done.signal()
        }
        defer { release.signal(); XCTAssertEqual(done.wait(timeout: .now() + 10), .success) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(returned.isSet, "Returned while a queued callback still ran")
    }

    /// Another conversation's provider whose folder was moved into the project since it
    /// launched holds a revert there while it stops: where it works now is asked.
    func testARevertWaitsForAProviderStoppingInAFolderMovedIntoItsProject() async throws {
        let root = try root(), repo = try GitTestRepo(commit: false)
        try repo.write("file.txt", "before\n")
        try repo.commit("initial")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        // The other conversation's provider process, working outside the project.
        let worker = Process()
        worker.executableURL = URL(fileURLWithPath: "/bin/sleep")
        worker.arguments = ["60"]
        worker.currentDirectoryURL = outside
        try worker.run()
        defer { worker.terminate(); worker.waitUntilExit() }
        let projectA = ProjectId(), projectB = ProjectId(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { $0 == projectA ? outside.path : repo.path }, factory: { _, directory, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.folder = AgentFolder(directory)
            runtime.onSend = {
                if directory == repo.path { try "after\n".write(toFile: repo.path + "/file.txt", atomically: true, encoding: .utf8) }
                callback(.status(.idle))
            }
            if directory == outside.path {
                runtime.processes = [worker.processIdentifier]
                box.install(runtime)
            }
            return runtime
        })
        defer { sessions.shutdown() }
        let a = SessionId(), b = SessionId()
        _ = try await sessions.handle(.create(session: a, project: projectA, provider: .claude))
        _ = try await sessions.handle(.create(session: b, project: projectB, provider: .claude))
        _ = try await sessions.handle(.send(session: b, text: "Change this file", model: nil))
        let done = try await waitForQueue(sessions, b) { $0.status == .idle && $0.turns?.first?.checkpoint != nil }
        let checkpoint = try XCTUnwrap(done.turns?.first?.checkpoint?.id)
        _ = try await sessions.handle(.send(session: a, text: "Work there", model: nil))
        _ = try await waitForQueue(sessions, a) { $0.status == .idle }
        let other = try XCTUnwrap(box.runtime)
        try FileManager.default.moveItem(at: outside, to: URL(fileURLWithPath: repo.path).appendingPathComponent("moved"))
        other.exiting = true
        do {
            _ = try await sessions.conversation(.revert(session: b, checkpoint: checkpoint, paths: nil, force: true))
            XCTFail("No revert while a provider stops in a folder moved into the project")
        } catch {
            XCTAssertEqual((error as? AgentRuntimeError)?.message, "The agent is still stopping. Try again shortly.")
        }
        XCTAssertEqual(try String(contentsOfFile: repo.path + "/file.txt", encoding: .utf8), "after\n")
        other.exiting = false
        guard case .revert(let reply) = try await sessions.conversation(.revert(session: b, checkpoint: checkpoint, paths: nil, force: true)) else {
            return XCTFail("Unexpected reply")
        }
        XCTAssertEqual(reply.reverted, ["file.txt"])
    }

    /// A provider started outside the conversations, as for discovery, holds a revert while
    /// it may still change files the revert restores, as in a folder inside the project.
    func testARevertWaitsForADiscoveryProviderInItsFolder() async throws {
        let root = try root(), repo = try GitTestRepo(commit: false)
        try repo.write("file.txt", "before\n")
        try repo.commit("initial")
        let directory = repo.path, inner = repo.path + "/inner"
        try FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: true)
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in directory }, factory: { _, _, _, callback in
            SkillCaptureRuntime(callback, onSend: { try "after\n".write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8) })
        })
        defer { sessions.shutdown() }
        let discovering = CompletionFlag(), folder = AgentFolder(inner)
        sessions.otherProvidersMayRun = { $0.holds(folder) && !discovering.isSet }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: id, text: "Change this file", model: nil))
        let done = try await waitForQueue(sessions, id) { $0.status == .idle && $0.turns?.first?.checkpoint != nil }
        let checkpoint = try XCTUnwrap(done.turns?.first?.checkpoint?.id)
        do {
            _ = try await sessions.conversation(.revert(session: id, checkpoint: checkpoint, paths: nil, force: true))
            XCTFail("No revert while a discovery provider may run in the folder")
        } catch {
            XCTAssertEqual((error as? AgentRuntimeError)?.message, "The agent is still stopping. Try again shortly.")
        }
        discovering.set()
        guard case .revert(let reply) = try await sessions.conversation(.revert(session: id, checkpoint: checkpoint, paths: nil, force: true)) else {
            return XCTFail("Unexpected reply")
        }
        XCTAssertEqual(reply.reverted, ["file.txt"])
    }

    /// A follow-up the user stopped after it may have reached the agent is reported as it
    /// failed, not as never sent, and isn't sent again.
    func testAFollowUpStoppedAfterHandOverIsReportedAsItFailed() async throws {
        let root = try root(), gate = root.appendingPathComponent("gate"), steering = DispatchSemaphore(value: 0)
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            // The agent took the follow-up, but never said so.
            runtime.onSteer = {
                steering.signal()
                while !FileManager.default.fileExists(atPath: gate.path) { try await Task.sleep(for: .milliseconds(20)) }
                throw AgentRuntimeError("The agent didn't acknowledge the message.")
            }
            return runtime
        })
        defer { sessions.shutdown() }
        defer { try? Data().write(to: gate) }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: id, text: "Work", model: nil))
        _ = try await waitForQueue(sessions, id) { $0.status == .working }
        let followUp = Task { try await sessions.handle(.send(session: id, text: "And this", model: nil)) }
        XCTAssertEqual(steering.wait(timeout: .now() + 10), .success)
        _ = try await sessions.handle(.interrupt(session: id))
        _ = try await waitForQueue(sessions, id) { $0.status == .idle }
        try Data().write(to: gate)
        do {
            _ = try await followUp.value
            XCTFail("The follow-up failed")
        } catch {
            XCTAssertEqual((error as? AgentRuntimeError)?.message, "The agent didn't acknowledge the message.", "\(error)")
        }
        try await Task.sleep(for: .milliseconds(300))
        let after = try await sessions.handle(.read(session: id))
        XCTAssertEqual(after.turns?.count, 1, "Not sent again")
    }

    /// A follow-up the user stopped never joins a turn the agent starts on its own later:
    /// its hand-over was cancelled, whenever it comes to be handed over.
    func testAStoppedFollowUpJoinsNoLaterTurn() async throws {
        let root = try root(), writer = DispatchQueue(label: "writer"), steered = TurnCounter(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, writer: writer, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSteer = { _ = steered.next() }
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: id, text: "Work", model: nil))
        _ = try await waitForQueue(sessions, id) { $0.status == .working }
        writer.suspend()
        var suspended = true
        defer { if suspended { writer.resume() } }
        let admitted = DispatchSemaphore(value: 0)
        sessions.followUpAdmitted = { admitted.signal() }
        let file = AgentChatAttachment(id: "notes", name: "notes.txt", mimeType: "text/plain", data: Data("Notes".utf8))
        let followUp = Task { try await sessions.handle(.send(session: id, text: "And this", model: nil, attachments: [file])) }
        XCTAssertEqual(admitted.wait(timeout: .now() + 10), .success)
        _ = try await sessions.handle(.interrupt(session: id))
        _ = try await waitForQueue(sessions, id) { $0.status == .idle }
        // The agent starts a turn of its own, as Claude does to answer a background agent.
        box.runtime?.callback(.status(.working))
        _ = try await waitForQueue(sessions, id) { $0.status == .working }
        writer.resume()
        suspended = false
        do {
            _ = try await followUp.value
            XCTFail("The stopped follow-up isn't delivered")
        } catch {
            XCTAssertTrue(error is AgentDeliveryNotStarted, "\(error)")
        }
        XCTAssertEqual(steered.count, 0, "Never handed to the agent")
    }

    /// A follow-up whose turn the provider ends by closing, as Codex can when stopped while
    /// compacting, is answered as never sent, not as delivered: a queued one stays queued.
    func testAFollowUpWhoseTurnClosesIsNotCountedDelivered() async throws {
        let root = try root(), writer = DispatchQueue(label: "writer")
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, writer: writer, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSteer = {}
            runtime.onInterrupt = { callback(.status(.closed)) }
            return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.send(session: id, text: "Work", model: nil))
        _ = try await waitForQueue(sessions, id) { $0.status == .working }
        writer.suspend()
        var suspended = true
        defer { if suspended { writer.resume() } }
        let admitted = DispatchSemaphore(value: 0)
        sessions.followUpAdmitted = { admitted.signal() }
        let file = AgentChatAttachment(id: "notes", name: "notes.txt", mimeType: "text/plain", data: Data("Notes".utf8))
        let followUp = Task { try await sessions.handle(.send(session: id, text: "And this", model: nil, attachments: [file])) }
        XCTAssertEqual(admitted.wait(timeout: .now() + 10), .success)
        _ = try await sessions.handle(.interrupt(session: id))
        do {
            _ = try await followUp.value
            XCTFail("Not delivered")
        } catch {
            XCTAssertTrue(error is AgentDeliveryNotStarted, "\(error)")
        }
        writer.resume()
        suspended = false
    }

    /// A follow-up the user stopped just as it reached the provider's hand-over never
    /// joins a turn the agent starts on its own afterwards.
    func testAFollowUpStoppedAtItsHandOverJoinsNoLaterTurn() async throws {
        let root = try root(), gate = root.appendingPathComponent("gate"), steered = TurnCounter(), box = AgentRuntimeBox()
        let entered = DispatchSemaphore(value: 0)
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSteer = { _ = steered.next() }
            runtime.onSteerEntered = {
                entered.signal()
                while !FileManager.default.fileExists(atPath: gate.path), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
            }
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        defer { try? Data().write(to: gate) }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: id, text: "Work", model: nil))
        _ = try await waitForQueue(sessions, id) { $0.status == .working }
        let followUp = Task { try await sessions.handle(.send(session: id, text: "And this", model: nil)) }
        XCTAssertEqual(entered.wait(timeout: .now() + 10), .success, "At its hand-over")
        _ = try await sessions.handle(.interrupt(session: id))
        _ = try await waitForQueue(sessions, id) { $0.status == .idle }
        box.runtime?.callback(.status(.working))
        _ = try await waitForQueue(sessions, id) { $0.status == .working }
        try Data().write(to: gate)
        do {
            _ = try await followUp.value
            XCTFail("The stopped follow-up isn't delivered")
        } catch {
            XCTAssertTrue(error is AgentDeliveryNotStarted, "\(error)")
        }
        XCTAssertEqual(steered.count, 0, "Never handed to the agent")
    }

    /// A conversation closed while its provider starts tells the provider to launch nothing
    /// more, before a revert can look for it.
    func testClosingTellsTheProviderToLaunchNothingMore() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: id, text: "Work", model: nil))
        let runtime = try XCTUnwrap(box.runtime)
        XCTAssertFalse(runtime.launchesRefused)
        _ = try await sessions.handle(.close(session: id))
        XCTAssertTrue(runtime.launchesRefused)
    }

    /// A follow-up stopped while its files were written never reaches the agent, nor
    /// starts a turn of its own once the stopped one ends.
    func testAFollowUpStoppedBeforeItsFilesAreWrittenIsNotDelivered() async throws {
        let root = try root(), writer = DispatchQueue(label: "writer"), steered = TurnCounter()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, writer: writer, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSteer = { _ = steered.next() }
            return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: id, text: "Work", model: nil))
        _ = try await waitForQueue(sessions, id) { $0.status == .working }
        writer.suspend()
        var suspended = true
        defer { if suspended { writer.resume() } }
        let file = AgentChatAttachment(id: "notes", name: "notes.txt", mimeType: "text/plain", data: Data("Notes".utf8))
        let admitted = DispatchSemaphore(value: 0)
        sessions.followUpAdmitted = { admitted.signal() }
        let followUp = Task { try await sessions.handle(.send(session: id, text: "And this", model: nil, attachments: [file])) }
        XCTAssertEqual(admitted.wait(timeout: .now() + 10), .success, "Stopped only once the follow-up is admitted")
        _ = try await sessions.handle(.interrupt(session: id))
        _ = try await waitForQueue(sessions, id) { $0.status == .idle }
        writer.resume()
        suspended = false
        do {
            _ = try await followUp.value
            XCTFail("The stopped follow-up isn't delivered")
        } catch {
            XCTAssertTrue(error is AgentDeliveryNotStarted, "\(error)")
        }
        try await Task.sleep(for: .milliseconds(300))
        let after = try await sessions.handle(.read(session: id))
        XCTAssertEqual(steered.count, 0, "Never handed to the agent")
        XCTAssertEqual(after.turns?.count, 1, "Nor a turn of its own")
    }

    /// A follow-up handed over just as the user stops the turn, which then ends before the
    /// agent takes it, isn't sent again as a turn of its own.
    func testAFollowUpStoppedAsItIsHandedOverStartsNoTurn() async throws {
        let root = try root(), gate = root.appendingPathComponent("gate"), steering = DispatchSemaphore(value: 0)
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            // The agent's turn ends before it takes the follow-up.
            runtime.onSteer = {
                steering.signal()
                while !FileManager.default.fileExists(atPath: gate.path) { try await Task.sleep(for: .milliseconds(20)) }
                throw AgentTurnFinishedError()
            }
            return runtime
        })
        defer { sessions.shutdown() }
        defer { try? Data().write(to: gate) }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: id, text: "Work", model: nil))
        _ = try await waitForQueue(sessions, id) { $0.status == .working }
        let followUp = Task { try await sessions.handle(.send(session: id, text: "And this", model: nil)) }
        XCTAssertEqual(steering.wait(timeout: .now() + 10), .success)
        _ = try await sessions.handle(.interrupt(session: id))
        _ = try await waitForQueue(sessions, id) { $0.status == .idle }
        try Data().write(to: gate)
        do {
            _ = try await followUp.value
            XCTFail("The stopped follow-up isn't sent again")
        } catch {
            XCTAssertTrue(error is AgentDeliveryNotStarted, "\(error)")
        }
        try await Task.sleep(for: .milliseconds(300))
        let after = try await sessions.handle(.read(session: id))
        XCTAssertEqual(after.turns?.count, 1, "No turn of its own")
    }

    /// An import never answers with a conversation being cleared, which is about to lose
    /// what it would have continued.
    func testAnImportIsNotAnsweredWithAConversationBeingCleared() async throws {
        let root = try root(), writer = DispatchQueue(label: "writer")
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, writer: writer,
                                         factory: { _, _, _, callback in FakeAgentRuntime(callback) })
        defer { sessions.shutdown() }
        let project = ProjectId(), first = SessionId()
        let saved = AgentHistoryTranscript(items: [AgentChatItem(id: "u1", kind: .user, text: "Earlier work")])
        let continued = try await sessions.importHistory(AgentHistoryImport(session: first, project: project, provider: .codex,
                                                                            providerSession: "thread-1")) { _ in saved }
        writer.sync {}
        writer.suspend()
        var suspended = true
        defer { if suspended { writer.resume() } }
        let clearing = Task { try await sessions.handle(.clear(session: first, archive: SessionId(), expectedRevision: continued.revision)) }
        let clearingMessage = "The conversation is being cleared. Try again shortly."
        var refusal: String?
        for _ in 0..<500 where refusal != clearingMessage {
            do {
                _ = try await sessions.importHistory(AgentHistoryImport(session: SessionId(), project: project, provider: .codex,
                                                                        providerSession: "thread-1")) { _ in saved }
            } catch { refusal = (error as? AgentRuntimeError)?.message }
            if refusal != clearingMessage { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertEqual(refusal, clearingMessage, "Refused rather than answered with the conversation being cleared")
        writer.resume()
        suspended = false
        _ = try await clearing.value
    }

    /// A clear that waited for the conversation's checkpoints while a revert was admitted
    /// behind it is refused, rather than clearing the conversation under the revert.
    func testAClearIsRefusedWhileARevertWaitsToBeApplied() async throws {
        let root = try root(), repo = try GitTestRepo(commit: false)
        try repo.write("file.txt", "before\n")
        try repo.commit("initial")
        let directory = repo.path, tools = root.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let restoring = tools.appendingPathComponent("restoring"), restored = tools.appendingPathComponent("restored")
        // Restoring a file waits for `restored`.
        let git = try AgentCheckpointTests.git("""
            for a in "$@"; do
              if [ "$a" = cat-file ]; then touch '\(restoring.path)'; while [ ! -f '\(restored.path)' ]; do sleep 0.05; done; fi
            done
            """, in: tools)
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in directory }, checkpoints: AgentCheckpointStore(git: git),
                                         factory: { _, _, _, callback in
            SkillCaptureRuntime(callback, onSend: { try "after\n".write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8) })
        })
        let waited = DispatchSemaphore(value: 0), proceed = CompletionFlag()
        defer { sessions.shutdown() }
        defer { proceed.set(); try? Data().write(to: restored) }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: id, text: "Change this file", model: nil))
        let done = try await waitForQueue(sessions, id) { $0.status == .idle && $0.turns?.first?.checkpoint != nil }
        sessions.clearStep = { step in
            guard step == .waited else { return }
            waited.signal()
            while !proceed.isSet { try? await Task.sleep(for: .milliseconds(10)) }
        }
        let clearing = Task { try await sessions.handle(.clear(session: id, archive: SessionId(), expectedRevision: done.revision)) }
        XCTAssertEqual(waited.wait(timeout: .now() + 10), .success, "The clear waited for the checkpoints")
        let revert = Task {
            try await sessions.conversation(.revert(session: id, checkpoint: try XCTUnwrap(done.turns?.first?.checkpoint?.id),
                                                    paths: nil, force: true))
        }
        try await waitUntil { FileManager.default.fileExists(atPath: restoring.path) }
        proceed.set()
        do {
            _ = try await clearing.value
            XCTFail("The clear is refused while the revert is applied")
        } catch {
            XCTAssertEqual((error as? AgentRuntimeError)?.message, "A revert is being applied. Try again shortly.")
        }
        try Data().write(to: restored)
        guard case .revert(let reply) = try await revert.value else { return XCTFail("Unexpected reply") }
        XCTAssertEqual(reply.reverted, ["file.txt"])
        let after = try await sessions.handle(.read(session: id))
        XCTAssertNil(after.resetID, "Not cleared")
    }

    /// A clear and a history import into the same conversation never overlap: whichever
    /// starts first is made or given up before the other is admitted.
    func testAClearAndAnImportIntoOneConversationExcludeEachOther() async throws {
        let root = try root(), gate = root.appendingPathComponent("gate"), writer = DispatchQueue(label: "writer")
        defer { try? Data().write(to: gate) }
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, writer: writer,
                                         factory: { _, _, _, callback in FakeAgentRuntime(callback) })
        defer { sessions.shutdown() }
        let project = ProjectId(), id = SessionId()
        let created = try await sessions.handle(.create(session: id, project: project, provider: .claude))
        let saved = AgentHistoryTranscript(items: [AgentChatItem(id: "u1", kind: .user, text: "Earlier work")])
        let reading = DispatchSemaphore(value: 0)
        let importing = Task {
            try await sessions.importHistory(AgentHistoryImport(session: id, project: project, provider: .codex, providerSession: "thread-1")) { _ in
                reading.signal()
                while !FileManager.default.fileExists(atPath: gate.path) { Thread.sleep(forTimeInterval: 0.02) }
                return saved
            }
        }
        XCTAssertEqual(reading.wait(timeout: .now() + 10), .success)
        do {
            _ = try await sessions.handle(.clear(session: id, archive: SessionId(), expectedRevision: created.revision))
            XCTFail("No clear while the import is made")
        } catch {
            XCTAssertEqual((error as? AgentRuntimeError)?.message, "A past conversation is being continued here. Try again shortly.")
        }
        try Data().write(to: gate)
        let imported = try await importing.value
        XCTAssertEqual(imported.providerSession, "thread-1")

        // A clear under way, held at its writes: no import is admitted meanwhile.
        let other = SessionId()
        let fresh = try await sessions.handle(.create(session: other, project: project, provider: .claude))
        writer.suspend()
        var suspended = true
        defer { if suspended { writer.resume() } }
        let clearing = Task { try await sessions.handle(.clear(session: other, archive: SessionId(), expectedRevision: fresh.revision)) }
        // Asked for from another project, an import changes nothing whatever the answer: it
        // reports the clear once that is under way.
        func refusal(_ request: AgentHistoryImport) async -> String? {
            do { _ = try await sessions.importHistory(request) { _ in saved }; return nil }
            catch { return (error as? AgentRuntimeError)?.message ?? (error as? ServiceError)?.message }
        }
        let clearingMessage = "The conversation is being cleared. Try again shortly."
        var probe: String?
        for _ in 0..<500 where probe != clearingMessage {
            probe = await refusal(AgentHistoryImport(session: other, project: ProjectId(), provider: .codex, providerSession: "probe"))
            if probe != clearingMessage { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertEqual(probe, clearingMessage, "Admitted, the clear holds the conversation")
        let refused = await refusal(AgentHistoryImport(session: other, project: project, provider: .codex, providerSession: "thread-2"))
        XCTAssertEqual(refused, clearingMessage, "No import while the clear is under way")
        writer.resume()
        suspended = false
        _ = try await clearing.value
    }

    /// Nothing is written once the store is released, however late a request finishes or
    /// however often it is shut down: the store's next owner may have saved since.
    func testNothingIsWrittenOnceTheStoreIsReleased() async throws {
        let root = try root(), gate = root.appendingPathComponent("gate"), writer = DispatchQueue(label: "writer")
        let changing = DispatchSemaphore(value: 0)
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, writer: writer, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            // The change asked for below waits for `gate`; the provider's first setting doesn't.
            runtime.onAccess = { mode in
                guard mode == .ask else { return }
                changing.signal()
                while !FileManager.default.fileExists(atPath: gate.path) { try await Task.sleep(for: .milliseconds(20)) }
            }
            return runtime
        })
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: id, text: "Work", model: nil))
        let access = Task { try await sessions.handle(.setAccess(session: id, mode: .ask)) }
        XCTAssertEqual(changing.wait(timeout: .now() + 10), .success)
        sessions.shutdown()
        // As the store's next owner might have, once it took over.
        let file = root.appendingPathComponent("\(id).json")
        try FileManager.default.removeItem(at: file)
        try Data().write(to: gate)
        _ = try? await access.value
        sessions.shutdown()
        writer.sync {}
        XCTAssertFalse(exists(file), "Neither the late access change nor a second shutdown writes it again")
    }

    /// A message without files starts its turn while records wait to be written; one with
    /// files waits for them, its files written in order with the conversation's others.
    func testOnlyAMessagesFilesWaitForRecordsToBeWritten() async throws {
        let root = try root(), writer = DispatchQueue(label: "writer"), sends = TurnCounter()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, writer: writer,
                                         factory: { _, _, _, callback in SkillCaptureRuntime(callback, onSend: { _ = sends.next() }) })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        writer.suspend()
        var suspended = true
        defer { if suspended { writer.resume() } }
        _ = try await sessions.handle(.send(session: id, text: "No files", model: nil))
        try await waitUntil(5) { sends.count == 1 }
        _ = try await waitForQueue(sessions, id) { $0.status == .idle }
        let file = AgentChatAttachment(id: "notes", name: "notes.txt", mimeType: "text/plain", data: Data("Notes".utf8))
        let sending = Task { try await sessions.handle(.send(session: id, text: "With a file", model: nil, attachments: [file])) }
        _ = try await waitForQueue(sessions, id) { $0.turns?.count == 2 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(sends.count, 1, "Its files are written first")
        writer.resume()
        suspended = false
        try await waitUntil(5) { sends.count == 2 }
        _ = try await sending.value
    }

    /// A history import still reading its transcript when the store is released writes
    /// none of its images after: the store's next owner may be importing it too.
    func testAHistoryImportFinishingAfterReleaseWritesNothing() async throws {
        let root = try root(), gate = root.appendingPathComponent("gate")
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in FakeAgentRuntime(callback) })
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
        var saved = AgentHistoryTranscript(items: [AgentChatItem(id: "u1", kind: .user, text: "Look at this")])
        saved.images = ["u1": [AgentChatAttachment(id: "shot", name: "shot.png", mimeType: "image/png", data: png)]]
        let read = saved, reading = DispatchSemaphore(value: 0), session = SessionId()
        let request = AgentHistoryImport(session: session, project: ProjectId(), provider: .codex, providerSession: "thread-1")
        let importing = Task {
            try await sessions.importHistory(request) { _ in
                reading.signal()
                while !FileManager.default.fileExists(atPath: gate.path) { Thread.sleep(forTimeInterval: 0.02) }
                return read
            }
        }
        XCTAssertEqual(reading.wait(timeout: .now() + 10), .success)
        sessions.shutdown()
        try Data().write(to: gate)
        do { _ = try await importing.value; XCTFail("Refused once the store is released") } catch {}
        XCTAssertFalse(exists(root.appendingPathComponent("attachments/\(session)")), "No image is written after release")
    }

    /// Images an import staged for a conversation it didn't make go with it, as when another
    /// conversation continued the same one meanwhile; a second import into a conversation
    /// already being made is refused, so neither stages over the other's images.
    func testARefusedImportLeavesNoImages() async throws {
        let root = try root(), gate = root.appendingPathComponent("gate"), writer = DispatchQueue(label: "writer")
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, writer: writer,
                                         factory: { _, _, _, callback in FakeAgentRuntime(callback) })
        defer { sessions.shutdown() }
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
        var saved = AgentHistoryTranscript(items: [AgentChatItem(id: "u1", kind: .user, text: "Look at this")])
        saved.images = ["u1": [AgentChatAttachment(id: "shot", name: "shot.png", mimeType: "image/png", data: png)]]
        let read = saved, reading = DispatchSemaphore(value: 0)
        let project = ProjectId(), first = SessionId(), other = SessionId()
        let slow = Task {
            try await sessions.importHistory(AgentHistoryImport(session: first, project: project, provider: .codex, providerSession: "thread-1")) { _ in
                reading.signal()
                while !FileManager.default.fileExists(atPath: gate.path) { Thread.sleep(forTimeInterval: 0.02) }
                return read
            }
        }
        XCTAssertEqual(reading.wait(timeout: .now() + 10), .success)
        do {
            _ = try await sessions.importHistory(AgentHistoryImport(session: first, project: project, provider: .codex,
                                                                    providerSession: "thread-2")) { _ in read }
            XCTFail("One import into a conversation at a time")
        } catch {}
        let continued = try await sessions.importHistory(AgentHistoryImport(session: other, project: project, provider: .codex,
                                                                            providerSession: "thread-1")) { _ in read }
        XCTAssertEqual(continued.session, other)
        try Data().write(to: gate)
        let result = try await slow.value
        XCTAssertEqual(result.session, other, "The conversation that continued it meanwhile")
        writer.sync {}
        let folder = AgentToolImages.directoryName(item: "u1")
        XCTAssertFalse(exists(root.appendingPathComponent("attachments/\(first)/\(folder)")), "Its images went")
        XCTAssertTrue(exists(root.appendingPathComponent("attachments/\(other)/\(folder)")), "The other conversation keeps its own")
    }

    /// Copies a clear stopped while making are reclaimed when the store opens again.
    func testCopiesAnInterruptedClearLeftAreReclaimed() async throws {
        let root = try root()
        let staging = root.appendingPathComponent("attachments/.copying-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: staging.appendingPathComponent("photo.png"))
        try restart(root)
        XCTAssertFalse(exists(staging))
    }

    /// A clear retried after one that stopped while copying redoes the copy, so the archive
    /// has everything before the conversation's own files go.
    func testARetriedClearCopiesEverythingAgain() async throws {
        let root = try root()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in SkillCaptureRuntime(callback) })
        defer { sessions.shutdown() }
        let id = SessionId(), archive = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        let attachment = AgentChatAttachment(id: "notes", name: "notes.txt", mimeType: "text/plain", data: Data("Notes".utf8))
        _ = try await sessions.handle(.send(session: id, text: "Read this", model: nil, attachments: [attachment]))
        let ready = try await waitForQueue(sessions, id) { $0.status == .idle }
        func files(_ folder: URL) -> Set<String> {
            Set((FileManager.default.enumerator(atPath: folder.path)?.allObjects as? [String] ?? []).filter {
                var directory: ObjCBool = false
                return FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path, isDirectory: &directory) && !directory.boolValue
            })
        }
        let originals = files(root.appendingPathComponent("attachments/\(id)"))
        XCTAssertFalse(originals.isEmpty)
        // What a clear that stopped while copying leaves: part of a copy.
        let partial = root.appendingPathComponent("attachments/\(archive)", isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: partial.appendingPathComponent("stale.txt"))

        _ = try await sessions.handle(.clear(session: id, archive: archive, expectedRevision: ready.revision))
        XCTAssertEqual(files(partial), originals, "The archive has every file the conversation had")
    }

    func testImportedImagesBecomeAttachmentsAndTurnsAreTimed() async throws {
        let root = try root()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in FakeAgentRuntime(callback) })
        defer { sessions.shutdown() }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var saved = AgentHistoryTranscript(items: [
            AgentChatItem(id: "u1", kind: .user, text: "What is this?", createdAt: start, updatedAt: start),
            AgentChatItem(id: "a1", kind: .assistant, text: "A logo.", createdAt: start.addingTimeInterval(7), updatedAt: start.addingTimeInterval(7)),
        ])
        saved.images["u1"] = [AgentChatAttachment(id: "img", name: "Image 1.png", mimeType: "image/png", data: png)]
        let request = AgentHistoryImport(session: SessionId(), project: ProjectId(), provider: .claude, providerSession: "claude-1")
        let imported = try await sessions.importHistory(request, transcript: { [saved] _ in saved })
        let descriptor = try XCTUnwrap(imported.items.first?.attachments?.first)
        XCTAssertEqual(descriptor.mimeType, "image/png")
        let reply = try await sessions.attachment(.init(session: request.session, item: "u1", attachment: descriptor.id))
        XCTAssertEqual(reply.attachment.data, png)
        XCTAssertEqual(imported.turns?.first.map { $0.completedAt?.timeIntervalSince($0.startedAt) }, 7)
        XCTAssertNoThrow(try imported.validate())
    }
}

extension AgentSessionsTests {
    func testClearTransfersAttachmentsOutputsAndCheckpointOwnershipToArchive() async throws {
        let storage = try root(), repo = try GitTestRepo(commit: false)
        try repo.write("file.txt", "before\n")
        try repo.commit("initial")
        let directory = repo.path
        let output = String(repeating: "Tool output\n", count: 3000)
        let sessions = try AgentSessions(root: storage, projectDirectory: { _ in directory }, factory: { _, _, _, callback in
            SkillCaptureRuntime(callback) {
                try "after\n".write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8)
                callback(.item(.init(id: "read", kind: .tool, text: "Read", tool: .init(name: "Read", category: .read, output: output, status: .completed))))
            }
        })
        let id = SessionId(), archive = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        let attachment = AgentChatAttachment(id: "notes", name: "notes.txt", mimeType: "text/plain", data: Data("Notes".utf8))
        _ = try await sessions.handle(.send(session: id, text: "Change this file", model: nil, attachments: [attachment]))
        let old = try await waitForQueue(sessions, id) { $0.status == .idle && $0.turns?.first?.checkpoint != nil }
        let checkpoint = try XCTUnwrap(old.turns?.first?.checkpoint)
        let user = try XCTUnwrap(old.items.first(where: { $0.kind == .user }))
        let record = try JSONDecoder().decode(AgentCheckpointRecord.self, from: Data(contentsOf: storage.appendingPathComponent("checkpoints/\(id)/\(checkpoint.id).json")))
        _ = try await sessions.handle(.clear(session: id, archive: archive, expectedRevision: old.revision))
        for folder in ["attachments", "outputs", "checkpoints"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: storage.appendingPathComponent("\(folder)/\(id)").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: storage.appendingPathComponent("\(folder)/\(archive)").path))
        }
        _ = try await sessions.handle(.send(session: id, text: "A new conversation", model: nil))
        sessions.shutdown()
        // Simulate a crash between committing the clear and retiring an old
        // checkpoint file. Startup must not mistake its refs for orphaned refs.
        let duplicate = storage.appendingPathComponent("checkpoints/\(id)/\(checkpoint.id).json")
        try FileManager.default.createDirectory(at: duplicate.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: duplicate)
        let restored = try AgentSessions(root: storage, projectDirectory: { _ in directory })
        defer { restored.shutdown() }
        let file = try await restored.attachment(.init(session: archive, item: user.id, attachment: attachment.id))
        XCTAssertEqual(file.attachment.data, attachment.data)
        guard case .toolOutput(let saved) = try await restored.conversation(.toolOutput(session: archive, item: "read")) else { return XCTFail("Missing archived output") }
        XCTAssertEqual(saved.text, output)
        let diff = try await restored.checkpoint(.init(session: archive, checkpoint: checkpoint.id, path: "file.txt"))
        XCTAssertTrue(diff.diff?.rows.contains { $0.text == "+after" } == true)
        XCTAssertEqual(try repo.run("rev-parse", record.before.reference).trimmingCharacters(in: .whitespacesAndNewlines), record.before.tree)
        XCTAssertEqual(try repo.run("rev-parse", record.after.reference).trimmingCharacters(in: .whitespacesAndNewlines), record.after.tree)
    }

    func testClearArchivesInPlaceAndFencesOldRuntimeAcrossRestart() async throws {
        let root = try root(), box = AgentRuntimeBox(), resumes = AgentRuntimeResumes()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, resume, callback in
            resumes.append(resume)
            let runtime = FakeAgentRuntime(callback); box.install(runtime); return runtime
        })
        let id = SessionId(), archive = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.send(session: id, text: "Keep my history", model: nil))
        let old = try XCTUnwrap(box.runtime)
        old.callback(.status(.idle))
        let previous = try await waitForQueue(sessions, id) { $0.status == .idle }
        let cleared = try await sessions.handle(.clear(session: id, archive: archive, expectedRevision: previous.revision))
        XCTAssertEqual(cleared.session, id)
        XCTAssertEqual(cleared.resetID, archive)
        XCTAssertNil(cleared.providerSession)
        XCTAssertTrue(cleared.items.isEmpty)
        let saved = try await sessions.handle(.read(session: archive))
        XCTAssertEqual(saved.items.map(\.text), previous.items.map(\.text))
        let resent = try await sessions.handle(.clear(session: id, archive: archive, expectedRevision: previous.revision))
        XCTAssertEqual(resent, cleared)
        old.callback(.item(.init(kind: .assistant, text: "Late old output")))
        _ = try await sessions.handle(.send(session: id, text: "Fresh context", model: nil))
        XCTAssertNil(resumes.values.last ?? nil)
        let current = try await sessions.handle(.read(session: id))
        XCTAssertFalse(current.items.contains { $0.text == "Late old output" })
        sessions.shutdown()
        let reloaded = try AgentSessions(root: root, projectDirectory: { _ in root.path })
        defer { reloaded.shutdown() }
        let restored = try await reloaded.handle(.read(session: id))
        XCTAssertEqual(restored.resetID, archive)
        XCTAssertFalse(restored.items.contains { $0.text == "Keep my history" })
        let restoredArchive = try await reloaded.handle(.read(session: archive))
        XCTAssertEqual(restoredArchive.items.map(\.text), previous.items.map(\.text))
    }

    func testClearRefusesBusyOrStaleConversationWithoutDiscardingMessages() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback); box.install(runtime); return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        let initial = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        let working = try await sessions.handle(.send(session: id, text: "Working", model: nil))
        for revision in [initial.revision, working.revision] {
            do { _ = try await sessions.handle(.clear(session: id, archive: SessionId(), expectedRevision: revision)); XCTFail("Must refuse") }
            catch { }
        }
        let kept = try await sessions.handle(.read(session: id))
        XCTAssertEqual(kept.items.map(\.text), working.items.map(\.text))
        XCTAssertEqual(kept.status, .working)
    }

    func testProviderCommandValidationDoesNotCreateATurnOrQueueEntry() async throws {
        let root = try root()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        for text in ["/review main", "/compact custom instructions", "/clear name", "/unknown arguments"] {
            do {
                _ = try await sessions.handle(.submit(session: id, prompt: AgentPrompt(text: text, model: nil, effort: nil, provider: .codex, planMode: false)))
                XCTFail("Invalid command accepted: \(text)")
            } catch { }
        }
        let snapshot = try await sessions.handle(.read(session: id))
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertTrue(snapshot.queuedPrompts?.isEmpty ?? true)
    }
}

private final class SkillCaptureRuntime: AgentSessionRuntime, @unchecked Sendable {
    private let lock = NSLock()
    let callback: @Sendable (AgentRuntimeEvent) -> Void
    let onSend: @Sendable () throws -> Void
    let onStop: @Sendable () -> Void
    private var received: [(String, [StagedAgentAttachment])] = []
    var sends: [(String, [StagedAgentAttachment])] { lock.withLock { received } }
    init(_ callback: @escaping @Sendable (AgentRuntimeEvent) -> Void, onSend: @escaping @Sendable () throws -> Void = {},
         onStop: @escaping @Sendable () -> Void = {}) {
        self.callback = callback; self.onSend = onSend; self.onStop = onStop
    }
    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?) async throws {}
    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?, attachments: [StagedAgentAttachment]) async throws {
        lock.withLock { received.append((text, attachments)) }
        try onSend()
        callback(.status(.idle))
    }
    func approve(request: String, allow: Bool) async throws {}
    func setAccess(_ mode: AgentAccessMode) async throws {}
    func interrupt() async throws {}
    func stop() { onStop() }
}

/// Counts a runtime's turns across threads.
private final class TurnCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var turns = 0
    var count: Int { lock.withLock { turns } }
    /// The number of the turn starting now.
    func next() -> Int { lock.withLock { turns += 1; return turns } }
}

/// Set once a task finishes, for checking that it hasn't yet.
final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var isSet: Bool { lock.withLock { done } }
    func set() { lock.withLock { done = true } }
    func clear() { lock.withLock { done = false } }
}

/// Blocks every Swift task worker, as synchronous calls made from a task group can: work
/// that needs a worker to finish then waits until they are freed.
private final class TaskWorkers: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)

    /// Runs `body` while no worker of any priority is free, then frees them.
    func whileBlocked<T>(_ body: () throws -> T) rethrows -> T {
        for priority in [TaskPriority.high, .medium, .low, .background] {
            // Until one doesn't start: it still waits for a worker.
            for _ in 0..<1024 {
                Task.detached(priority: priority) { [self] in hold() }
                guard started.wait(timeout: .now() + 0.5) == .success else { break }
            }
        }
        defer { released.signal() }
        return try body()
    }

    private func hold() {
        started.signal()
        released.wait()
        released.signal()
    }
}

extension AgentSessionsTests {
    func testNativeClaudeSkillUsesProviderCommandWithoutInstructionMarker() async throws {
        let root = try root()
        let capture = SkillCaptureRuntime { _ in }
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, _ in capture })
        defer { sessions.shutdown() }
        sessions.composerCatalog = { _ in
            var catalog = AgentComposerContextReply(skills: [])
            catalog.commands = [.init(name: "review", description: "Review", isSkill: true, aliases: ["plugin:review"])]
            return catalog
        }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        let prompt = AgentPrompt(text: "/skill:plugin:review check this change", model: nil, effort: nil, provider: .claude, planMode: false)
        _ = try await sessions.handle(.submit(session: id, prompt: prompt))
        _ = try await waitForQueue(sessions, id) { $0.queuedPrompts?.isEmpty == true }
        let delivery = try XCTUnwrap(capture.sends.first)
        XCTAssertEqual(delivery.0, "/plugin:review check this change")
        XCTAssertTrue(delivery.1.isEmpty)
        let snapshot = try await sessions.handle(.read(session: id))
        XCTAssertEqual(snapshot.items.first(where: { $0.kind == .user })?.text, prompt.text)
        sessions.composerCatalog = { _ in throw AgentRuntimeError("Provider unavailable") }
        _ = try await sessions.handle(.submit(session: id, prompt: prompt))
        XCTAssertEqual(capture.sends.count, 1)
    }

    func testTypedSkillResolvesBeforeAcceptanceAndRetriesDoNotRepeatIt() async throws {
        let root = try root()
        let capture = SkillCaptureRuntime { _ in }
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, _ in capture })
        defer { sessions.shutdown() }
        sessions.composerCatalog = { _ in .init(skills: [.init(id: "review", name: "review", description: "Review", path: ServerPath("/skills/review/SKILL.md"), instructions: "Check concurrency.")]) }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        let prompt = AgentPrompt(text: "/skill:review check this change", model: nil, effort: nil, provider: .codex, planMode: false)
        _ = try await sessions.handle(.submit(session: id, prompt: prompt))
        _ = try await waitForQueue(sessions, id) { $0.queuedPrompts?.isEmpty == true }
        let delivery = try XCTUnwrap(capture.sends.first)
        XCTAssertFalse(delivery.0.hasPrefix("/skill:"))
        XCTAssertTrue(delivery.0.contains("check this change"))
        let instructions = try XCTUnwrap(delivery.1.first?.attachment)
        XCTAssertTrue(String(decoding: instructions.data, as: UTF8.self).contains("Check concurrency."))
        sessions.composerCatalog = { _ in throw AgentRuntimeError("Skill removed") }
        _ = try await sessions.handle(.submit(session: id, prompt: prompt))
        XCTAssertEqual(capture.sends.count, 1, "An accepted skill retry must not rediscover or redeliver")
    }

    func testFailedClearArchiveKeepsOriginalTranscriptAndContext() async throws {
        let root = try root()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path })
        defer { sessions.shutdown() }
        let id = SessionId(), archive = SessionId()
        let original = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(archive.description + ".json"), withIntermediateDirectories: true)
        do { _ = try await sessions.handle(.clear(session: id, archive: archive, expectedRevision: original.revision)); XCTFail("Must fail saving archive") }
        catch { }
        let retained = try await sessions.handle(.read(session: id))
        XCTAssertEqual(retained, original)
    }
}

extension AgentSessionsTests {
    func testSkillDiscoveryInFlightCannotSendIntoClearedContext() async throws {
        let root = try root(), gate = AgentSubmissionGate()
        let started = expectation(description: "Discovery started")
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            XCTFail("An old prepared prompt must not start a new context")
            return FakeAgentRuntime(callback)
        })
        defer { sessions.shutdown() }
        sessions.composerCatalog = { _ in
            started.fulfill()
            await gate.wait()
            return .init(skills: [.init(id: "review", name: "review", description: "", path: ServerPath("/skills/review/SKILL.md"), instructions: "Review code")])
        }
        let id = SessionId()
        let initial = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        let delivery = Task {
            try await sessions.handle(.submit(session: id, prompt: AgentPrompt(text: "/skill:review old context", model: nil, effort: nil, provider: .codex, planMode: false)))
        }
        await fulfillment(of: [started], timeout: 5)
        _ = try await sessions.handle(.clear(session: id, archive: SessionId(), expectedRevision: initial.revision))
        await gate.release()
        do { _ = try await delivery.value; XCTFail("Must reject stale prepared message") } catch { }
        let cleared = try await sessions.handle(.read(session: id))
        XCTAssertTrue(cleared.items.isEmpty)
    }
}

extension AgentSessionsTests {
    func testForkCopiesTheConversationAndForksItsProviderSessionUntilItHasItsOwn() async throws {
        let root = try root(), box = AgentRuntimeBox(), messages = AgentEventCount()
        let factory: AgentSessions.Factory = { _, _, resume, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.providerSession = resume == nil ? "source-conversation" : "forked-conversation"
            runtime.onSend = {
                messages.increment()
                callback(.providerMessage("message-\(messages.count)"))
                callback(.status(.idle))
            }
            box.install(runtime)
            return runtime
        }
        var sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: factory)
        let source = SessionId(), fork = SessionId(), project = ProjectId()
        _ = try await sessions.handle(.create(session: source, project: project, provider: .claude))
        _ = try await sessions.handle(.setAccess(session: source, mode: .fullAccess))
        _ = try await sessions.handle(.send(session: source, text: "Start", model: "claude-opus-5-5"))
        let original = try await sessions.handle(.read(session: source))
        XCTAssertEqual(original.providerSession, "source-conversation")

        let copied = try await sessions.handle(.fork(session: fork, from: source))
        XCTAssertEqual(copied.session, fork)
        XCTAssertEqual(copied.project, project)
        XCTAssertEqual(copied.items.map(\.text), original.items.map(\.text))
        XCTAssertEqual(copied.accessMode, .fullAccess)
        XCTAssertEqual(copied.model, "claude-opus-5-5")
        XCTAssertEqual(copied.status, .idle)
        let again = try await sessions.handle(.fork(session: fork, from: source))
        XCTAssertEqual(again, copied)
        // What the source says after the fork stays out of it, and out of a fork of the fork.
        _ = try await sessions.handle(.send(session: source, text: "More", model: "claude-opus-5-5"))
        let branch = SessionId()
        _ = try await sessions.handle(.fork(session: branch, from: fork))

        // The fork survives a server restart before its first message.
        sessions.shutdown()
        sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: factory)
        defer { sessions.shutdown() }
        let continued = try await sessions.handle(.send(session: fork, text: "Next", model: "claude-opus-5-5"))
        XCTAssertEqual(box.runtime?.launches.first?.forkSource, "source-conversation")
        XCTAssertEqual(box.runtime?.launches.first?.forkPoint, "message-1")
        XCTAssertEqual(continued.providerSession, "forked-conversation")
        XCTAssertEqual(continued.items.filter { $0.kind == .user }.map(\.text), ["Start", "Next"])
        let unchanged = try await sessions.handle(.read(session: source))
        XCTAssertEqual(unchanged.items.filter { $0.kind == .user }.map(\.text), ["Start", "More"])

        sessions.shutdown()
        sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: factory)
        _ = try await sessions.handle(.send(session: fork, text: "Later", model: "claude-opus-5-5"))
        XCTAssertNil(box.runtime?.launches.first?.forkSource, "A fork with its own conversation resumes it")
        XCTAssertNil(box.runtime?.launches.first?.forkPoint)
        _ = try await sessions.handle(.send(session: branch, text: "Branch", model: "claude-opus-5-5"))
        XCTAssertEqual(box.runtime?.launches.first?.forkSource, "source-conversation")
        XCTAssertEqual(box.runtime?.launches.first?.forkPoint, "message-1")
    }
}


extension AgentSessionsTests {
    func testCatalogChangesStartFreshProviderThreadAndRetainTranscript() async throws {
        let root = try root(), resumes = AgentRuntimeResumes()
        let factory: AgentSessions.Factory = { _, _, resume, callback in
            resumes.append(resume)
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = { callback(.item(.init(kind: .assistant, text: "Kept reply"))); callback(.status(.idle)) }
            return runtime
        }
        let id = SessionId(), project = ProjectId()
        var sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: factory)
        sessions.applicationToolSignature = "catalog-one"
        _ = try await sessions.handle(.create(session: id, project: project, provider: .codex))
        _ = try await sessions.handle(.send(session: id, text: "First", model: nil))
        _ = try await waitForQueue(sessions, id) { $0.status == .idle }
        sessions.shutdown()
        sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: factory)
        sessions.applicationToolSignature = "catalog-two"
        defer { sessions.shutdown() }
        _ = try await sessions.handle(.send(session: id, text: "Second", model: nil))
        let final = try await waitForQueue(sessions, id) { $0.status == .idle }
        XCTAssertTrue(final.items.contains { $0.text == "First" })
        XCTAssertTrue(final.items.contains { $0.text.contains("capabilities changed") })
        XCTAssertNil(resumes.values.last ?? nil)
    }

    func testApplicationResultSurvivesProviderEchoAndRetainsFullArguments() async throws {
        let root = try root()
        let input = "{\"value\":\"" + String(repeating: "a", count: 12000) + "\"}"
        let image = AgentChatAttachment(name: "frame.jpg", mimeType: "image/jpeg", data: Data([1, 2, 3]))
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = {
                var activity = AgentToolActivity(name: "review", input: input, output: "Reviewed", status: .completed)
                activity.isApplicationTool = true
                callback(.toolItem(.init(id: "review", kind: .tool, text: "review", tool: activity, attachments: [image.descriptor]), images: [image]))
                callback(.item(.init(id: "review", kind: .tool, text: "review", tool: .init(name: "review", output: "data:image/jpeg;base64,AAAA", status: .completed))))
                callback(.status(.idle))
            }
            return runtime
        })
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.send(session: id, text: "Review", model: nil))
        let snapshot = try await waitForQueue(sessions, id) { $0.status == .idle }
        let tool = try XCTUnwrap(snapshot.items.first { $0.id == "review" })
        XCTAssertEqual(tool.attachments, [image.descriptor])
        XCTAssertTrue(tool.tool?.output?.hasPrefix("Reviewed") == true)
        guard case .toolOutput(let full) = try await sessions.conversation(.toolOutput(session: id, item: "review")) else { return XCTFail("No full arguments") }
        XCTAssertTrue(full.text.contains(input))
        sessions.shutdown()
        let restored = try AgentSessions(root: root, projectDirectory: { _ in root.path })
        defer { restored.shutdown() }
        let reloaded = try await restored.handle(.read(session: id))
        XCTAssertEqual(reloaded.items.first { $0.id == "review" }?.attachments, [image.descriptor])
    }
}

extension AgentSessionsTests {
    private func steps(_ sessions: AgentSessions, _ id: SessionId, _ toolUseID: String, before: Int? = nil) async throws -> AgentSubagentSteps {
        let request: AgentConversationRequest = before.map { .subagentStepsPage(session: id, toolUseID: toolUseID, before: $0, limit: 200) }
            ?? .subagentSteps(session: id, toolUseID: toolUseID)
        guard case .subagentSteps(let steps) = try await sessions.conversation(request) else { throw ServiceError(.badRequest, "Unexpected reply") }
        XCTAssertNoThrow(try AgentConversationReply.subagentSteps(steps).validate())
        return steps
    }

    /// T1: a child's revision moves with its content, not only its count: a running tool
    /// that completes in place, and a bounded window rolling over at the same size.
    func testChildStepsRevisionFollowsContentChangesAtTheSameCount() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback); box.install(runtime); return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.submit(session: id, prompt: AgentPrompt(text: "Launch", model: nil, effort: nil, provider: .claude, planMode: false)))
        _ = try await waitForQueue(sessions, id) { $0.status == .working }
        let agent = AgentSubagent(id: "a1", toolUseID: "toolu_child", description: "Audit")
        box.runtime?.callback(.subagents([agent]))
        let running = AgentChatItem(id: "t1", kind: .tool, text: "Bash", isComplete: false,
                                    tool: .init(name: "Bash", category: .command, input: "ls", status: .running))
        box.runtime?.callback(.subagentSteps(toolUseID: "toolu_child", items: [running]))
        let first = try await waitForQueue(sessions, id) { $0.subagents?.first?.stepsRevision != nil }
        let revision = try XCTUnwrap(first.subagents?.first?.stepsRevision)
        XCTAssertEqual(first.subagents?.first?.steps, 1)
        var completed = running
        completed.isComplete = true
        completed.tool?.status = .completed
        completed.tool?.output = "Package.swift"
        box.runtime?.callback(.subagentSteps(toolUseID: "toolu_child", items: [completed]))
        let second = try await waitForQueue(sessions, id) { ($0.subagents?.first?.stepsRevision ?? 0) > revision }
        XCTAssertEqual(second.subagents?.first?.steps, 1, "The count is unchanged")
        let read1 = try await steps(sessions, id, "toolu_child")

        XCTAssertEqual(read1.items.first?.tool?.output, "Package.swift")
        let unchanged = try XCTUnwrap(second.subagents?.first?.stepsRevision)
        box.runtime?.callback(.subagentSteps(toolUseID: "toolu_child", items: [completed]))
        _ = try await sessions.handle(.read(session: id))
        let read2 = try await steps(sessions, id, "toolu_child")

        XCTAssertEqual(read2.revision, unchanged, "Nothing changed, so the revision stays")
        // The provider's own window of 200 rolls over: the server keeps the steps that left it.
        let window = (0..<200).map { AgentChatItem(id: "s\($0)", kind: .assistant, text: "Step \($0)") }
        box.runtime?.callback(.subagentSteps(toolUseID: "toolu_child", items: window))
        box.runtime?.callback(.subagentSteps(toolUseID: "toolu_child", items: Array(window.dropFirst()) + [AgentChatItem(id: "s200", kind: .assistant, text: "Step 200")]))
        let rolled = try await waitForQueue(sessions, id) { $0.subagents?.first?.steps == 202 }
        XCTAssertGreaterThan(try XCTUnwrap(rolled.subagents?.first?.stepsRevision), unchanged)
        let newest = try await steps(sessions, id, "toolu_child")
        XCTAssertEqual(newest.items.count, 200)
        XCTAssertEqual(newest.start, 2)
        XCTAssertEqual(newest.total, 202)
        let read3 = try await steps(sessions, id, "toolu_child", before: 2)

        XCTAssertEqual(read3.items.map(\.id), ["t1", "s0"])
    }

    /// T5: a finished child's steps outlast the provider process and a server restart,
    /// identify the steps that exceeded retention, belong to their conversation and project,
    /// move with a cleared conversation's archive, and go when the conversation is deleted.
    func testChildStepsAreSavedBoundedScopedAndRemovedWithTheirConversation() async throws {
        let root = try root(), box = AgentRuntimeBox()
        func open(retention: TimeInterval = AgentSessions.closedRetention) throws -> AgentSessions {
            try AgentSessions(root: root, projectDirectory: { _ in root.path }, retention: .deleteClosed(after: retention), factory: { _, _, _, callback in
                let runtime = FakeAgentRuntime(callback); box.install(runtime); return runtime
            })
        }
        let sessions = try open()
        let id = SessionId(), project = ProjectId()
        _ = try await sessions.handle(.create(session: id, project: project, provider: .claude))
        _ = try await sessions.handle(.submit(session: id, prompt: AgentPrompt(text: "Launch", model: nil, effort: nil, provider: .claude, planMode: false)))
        _ = try await waitForQueue(sessions, id) { $0.status == .working }
        let agent = AgentSubagent(id: "a1", toolUseID: "toolu_child", description: "Audit")
        box.runtime?.callback(.subagents([agent]))
        // Eleven disjoint windows of 200 steps exceed the 2,000 a child keeps.
        for window in 0..<11 {
            box.runtime?.callback(.subagentSteps(toolUseID: "toolu_child", items: (0..<200).map {
                AgentChatItem(id: "w\(window)-\($0)", kind: .assistant, text: "Window \(window) step \($0)")
            }))
        }
        var finished = agent
        finished.status = .completed
        box.runtime?.callback(.subagents([finished]))
        box.runtime?.callback(.status(.idle))
        let idle = try await waitForQueue(sessions, id) { $0.status == .idle && $0.subagents?.first?.status == .completed }
        XCTAssertEqual(idle.subagents?.first?.steps, 2200)
        let live = try await steps(sessions, id, "toolu_child")
        sessions.shutdown()

        let restarted = try open()
        let saved = try await steps(restarted, id, "toolu_child")
        XCTAssertEqual(saved, live, "The finished child reads the same after a restart")
        XCTAssertEqual(saved.omitted, 200, "The steps past retention are identified")
        XCTAssertEqual(saved.total, 2200)
        XCTAssertEqual(saved.start, 2000)
        XCTAssertNil(saved.unavailable)
        let oldest = try await steps(restarted, id, "toolu_child", before: 400)
        XCTAssertEqual(oldest.start, 200)
        XCTAssertEqual(oldest.items.first?.id, "w1-0")
        let read4 = try await steps(restarted, id, "toolu_child", before: 200)

        XCTAssertEqual(read4.items, [], "Omitted steps are gone, not refetched")
        let older = try await steps(restarted, id, "toolu_never_saved")
        XCTAssertEqual(older.unavailable, true, "A child an older server never saved says so")
        XCTAssertEqual(older.items, [])

        // Another conversation, or the same record under another project, never reads it.
        let other = SessionId()
        _ = try await restarted.handle(.create(session: other, project: project, provider: .claude))
        let read5 = try await steps(restarted, other, "toolu_child")

        XCTAssertEqual(read5.unavailable, true)
        XCTAssertNil(AgentChildTranscripts.load(root: root, session: id, toolUseID: "toolu_child", project: ProjectId()))

        // Clearing moves the steps to the archive with the rest of the conversation.
        let current = try await restarted.handle(.read(session: id))
        let archive = SessionId()
        _ = try await restarted.handle(.clear(session: id, archive: archive, expectedRevision: current.revision))
        let read6 = try await steps(restarted, archive, "toolu_child")

        XCTAssertEqual(read6.total, 2200)
        let read7 = try await steps(restarted, id, "toolu_child")

        XCTAssertEqual(read7.unavailable, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AgentChildTranscripts.directory(root: root, session: id).path))
        _ = try await restarted.handle(.close(session: archive))
        restarted.shutdown()

        // The conversation's cleanup deletes its children's steps with everything else.
        let expiring = try open(retention: 0)
        expiring.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(archive.description + ".json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: AgentChildTranscripts.directory(root: root, session: archive).path))
    }
}
