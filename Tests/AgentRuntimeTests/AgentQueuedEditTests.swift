import AgentCore
import Foundation
import XCTest
@testable import AgentRuntime

/// A provider that records what reached it and stays working until told otherwise.
private final class QueueFakeRuntime: AgentSessionRuntime, @unchecked Sendable {
    let callback: @Sendable (AgentRuntimeEvent) -> Void
    private let lock = NSLock()
    private var delivered: [(text: String, attachments: [AgentChatAttachment])] = []
    var deliveries: [(text: String, attachments: [AgentChatAttachment])] { lock.withLock { delivered } }
    init(_ callback: @escaping @Sendable (AgentRuntimeEvent) -> Void) { self.callback = callback }
    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?) async throws {
        lock.withLock { delivered.append((text, [])) }
    }
    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?, attachments: [StagedAgentAttachment]) async throws {
        lock.withLock { delivered.append((text, attachments.map(\.attachment))) }
    }
    func steer(text: String, attachments: [StagedAgentAttachment]) async throws {
        lock.withLock { delivered.append((text, attachments.map(\.attachment))) }
    }
    func approve(request: String, allow: Bool) async throws {}
    func setAccess(_ mode: AgentAccessMode) async throws {}
    func interrupt() async throws { callback(.status(.idle)) }
    func stop() {}
}

private final class QueueRuntimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: QueueFakeRuntime?
    var runtime: QueueFakeRuntime? { lock.withLock { value } }
    func install(_ runtime: QueueFakeRuntime) { lock.withLock { value = runtime } }
}

final class AgentQueuedEditTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aq-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func sessions(_ root: URL, _ box: QueueRuntimeBox) throws -> AgentSessions {
        try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = QueueFakeRuntime(callback); box.install(runtime); return runtime
        })
    }

    private func settle(_ sessions: AgentSessions, _ id: SessionId, until predicate: (AgentChatSnapshot) -> Bool) async throws -> AgentChatSnapshot {
        for _ in 0..<300 {
            let snapshot = try await sessions.handle(.read(session: id))
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AgentRuntimeError("The conversation did not settle")
    }

    private func screenshot(_ name: String, byte: UInt8) -> AgentChatAttachment {
        AgentChatAttachment(name: name, mimeType: "image/png", data: Data(repeating: byte, count: 64))
    }

    /// Starts a working turn and queues `prompt` behind it.
    private func queue(_ prompt: AgentPrompt, in sessions: AgentSessions) async throws -> SessionId {
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.submit(session: id, prompt: AgentPrompt(text: "Working", model: nil, effort: nil, provider: .codex, planMode: false)))
        _ = try await settle(sessions, id) { $0.status == .working && $0.queuedPrompts?.isEmpty == true }
        _ = try await sessions.handle(.submit(session: id, prompt: prompt))
        return id
    }

    func testReplacingAScreenshotIsAtomicAndAFailedSaveLeavesTheOriginalUsable() async throws {
        let root = try root(), box = QueueRuntimeBox()
        let sessions = try sessions(root, box)
        defer { sessions.shutdown() }
        let original = screenshot("Before.png", byte: 1), notes = AgentChatAttachment(name: "Notes.txt", mimeType: "text/plain", data: Data("n".utf8))
        let prompt = AgentPrompt(text: "Compare these", model: nil, effort: nil, provider: .codex, planMode: false, attachments: [original, notes])
        let id = try await queue(prompt, in: sessions)
        let replacement = screenshot("After.png", byte: 2)
        let edit = AgentQueuedEdit(text: "Compare the new one", attachments: [.add(replacement), .keep(id: notes.id)])

        // A stale revision, an unknown kept attachment, and an empty prompt each change nothing.
        for (request, label) in [
            (AgentChatRequest.updateQueued(session: id, id: prompt.id, edit: edit, expectedRevision: 7), "stale"),
            (.updateQueued(session: id, id: prompt.id, edit: .init(text: "x", attachments: [.keep(id: "missing")]), expectedRevision: 0), "unknown"),
            (.updateQueued(session: id, id: prompt.id, edit: .init(text: " ", attachments: []), expectedRevision: 0), "empty"),
        ] {
            do { _ = try await sessions.handle(request); XCTFail("The \(label) update must fail") } catch {}
            let unchanged = try await sessions.handle(.read(session: id))
            XCTAssertEqual(unchanged.queuedPrompts?.first?.text, "Compare these", label)
            XCTAssertEqual(unchanged.queuedPrompts?.first?.attachments.map(\.id), [original.id, notes.id], label)
            XCTAssertEqual(unchanged.queuedPrompts?.first?.revision, 0, label)
        }
        // The original entry stays whole: its attachment can still be read from the queue.
        let held = try await sessions.attachment(.init(session: id, item: prompt.id, attachment: original.id))
        XCTAssertEqual(held.attachment.data, original.data)

        let updated = try await sessions.handle(.updateQueued(session: id, id: prompt.id, edit: edit, expectedRevision: 0))
        let entry = try XCTUnwrap(updated.queuedPrompts?.first)
        XCTAssertEqual(entry.text, "Compare the new one")
        XCTAssertEqual(entry.attachments.map(\.name), ["After.png", "Notes.txt"], "The replacement keeps its place")
        XCTAssertEqual(entry.revision, 1)
        let fetched = try await sessions.attachment(.init(session: id, item: prompt.id, attachment: replacement.id))
        XCTAssertEqual(fetched.attachment.data, replacement.data)
        do { _ = try await sessions.attachment(.init(session: id, item: prompt.id, attachment: original.id)); XCTFail("The replaced attachment is gone") } catch {}
        // Resending the original submission is recognized and never queues it again.
        let resent = try await sessions.handle(.submit(session: id, prompt: prompt))
        XCTAssertEqual(resent.queuedPrompts?.count, 1)
        XCTAssertEqual(resent.queuedPrompts?.first?.text, "Compare the new one")

        box.runtime?.callback(.status(.idle))
        _ = try await settle(sessions, id) { $0.queuedPrompts?.isEmpty == true }
        let delivered = try XCTUnwrap(box.runtime?.deliveries.last)
        XCTAssertEqual(delivered.text, "Compare the new one")
        XCTAssertEqual(delivered.attachments.map(\.data), [replacement.data, notes.data])
        XCTAssertEqual(box.runtime?.deliveries.filter { $0.text.hasPrefix("Compare") }.count, 1)
    }

    func testAttachmentOnlyPromptCanLoseItsAttachmentOnlyByGainingText() async throws {
        let root = try root(), box = QueueRuntimeBox()
        let sessions = try sessions(root, box)
        defer { sessions.shutdown() }
        let shot = screenshot("Only.png", byte: 3)
        let prompt = AgentPrompt(text: "", model: nil, effort: nil, provider: .codex, planMode: false, attachments: [shot])
        let id = try await queue(prompt, in: sessions)
        do {
            _ = try await sessions.handle(.updateQueued(session: id, id: prompt.id, edit: .init(text: "", attachments: []), expectedRevision: 0))
            XCTFail("An empty prompt must be refused")
        } catch {}
        let unchanged = try await sessions.handle(.read(session: id))
        XCTAssertEqual(unchanged.queuedPrompts?.first?.attachments.map(\.id), [shot.id])
        // The queue itself refuses it too, with a reason, should a request get past validation.
        var inbox = AgentPromptInbox()
        try inbox.submit(prompt)
        XCTAssertThrowsError(try inbox.update(prompt.id, revision: 0, edit: .init(text: "", attachments: []))) { error in
            XCTAssertTrue(error.localizedDescription.contains("needs text or an attachment"), error.localizedDescription)
        }
        XCTAssertEqual(inbox.visible.first?.attachments.map(\.id), [shot.id])
        let texted = try await sessions.handle(.updateQueued(session: id, id: prompt.id, edit: .init(text: "Just text now", attachments: []), expectedRevision: 0))
        XCTAssertEqual(texted.queuedPrompts?.first?.attachments, [])
        XCTAssertEqual(texted.queuedPrompts?.first?.text, "Just text now")
    }

    func testUpdatedQueueSurvivesRestartAndLegacyEditStillWorks() async throws {
        let root = try root(), box = QueueRuntimeBox()
        var sessions: AgentSessions? = try self.sessions(root, box)
        let shot = screenshot("Shot.png", byte: 4)
        let prompt = AgentPrompt(text: "Look", model: nil, effort: nil, provider: .codex, planMode: false, attachments: [shot])
        let id = try await queue(prompt, in: try XCTUnwrap(sessions))
        let added = AgentChatAttachment(name: "Log.txt", mimeType: "text/plain", data: Data("log".utf8))
        _ = try await sessions?.handle(.updateQueued(session: id, id: prompt.id,
            edit: .init(text: "Look again", settings: .init(model: "gpt-x", effort: nil, planMode: false), attachments: [.keep(id: shot.id), .add(added)]),
            expectedRevision: 0))
        _ = try await sessions?.handle(.editQueued(session: id, id: prompt.id, text: "Look once more", expectedRevision: 1))
        sessions?.shutdown()
        sessions = nil
        let restarted = try self.sessions(root, box)
        defer { restarted.shutdown() }
        let snapshot = try await restarted.handle(.read(session: id))
        let entry = try XCTUnwrap(snapshot.queuedPrompts?.first)
        XCTAssertEqual(entry.text, "Look once more")
        XCTAssertEqual(entry.attachments.map(\.name), ["Shot.png", "Log.txt"])
        let log = try await restarted.attachment(.init(session: id, item: prompt.id, attachment: added.id))
        XCTAssertEqual(log.attachment.data, added.data)
        XCTAssertEqual(snapshot.queuePaused, true, "A restart holds the queue for the user")
    }

    func testInboxWrittenBeforeAttachmentEditsStillLoads() throws {
        let root = try root()
        let prompt = AgentPrompt(text: "Old", model: nil, effort: nil, provider: .claude, planMode: false)
        let display = try JSONEncoder().encode(AgentQueuedPrompt(prompt: prompt))
        let promptJSON = try JSONEncoder().encode(prompt)
        let legacy = """
        {"records":[{"id":"\(prompt.id)","fingerprint":"f","prompt":\(String(decoding: promptJSON, as: UTF8.self)),"display":\(String(decoding: display, as: UTF8.self))}],"paused":false}
        """
        let file = root.appendingPathComponent("inbox.json")
        try Data(legacy.utf8).write(to: file)
        var inbox = try AgentPromptInbox.load(file)
        try inbox.update(prompt.id, revision: 0, edit: .init(text: "New", attachments: []))
        XCTAssertEqual(inbox.visible.first?.text, "New")
        XCTAssertEqual(inbox.records.first?.fingerprint, "f", "Editing keeps the submission's identity")
    }
}
