import AgentCore
import AppKit
import XCTest
@testable import AgentRuntime
@testable import AgentUI

/// A provider fixture: it records what reached it, by follow-up or by new turn, and stays
/// working until the test ends the turn. No executable or credentials are involved.
final class ComposerFakeRuntime: AgentSessionRuntime, @unchecked Sendable {
    let callback: @Sendable (AgentRuntimeEvent) -> Void
    private let lock = NSLock()
    private var turnTexts: [String] = []
    private var followUps: [String] = []
    var sends: [String] { lock.withLock { turnTexts } }
    var steers: [String] { lock.withLock { followUps } }
    /// Every delivery of `text`, as a new turn or a follow-up.
    func deliveries(of text: String) -> Int { lock.withLock { (turnTexts + followUps).filter { $0 == text }.count } }
    init(_ callback: @escaping @Sendable (AgentRuntimeEvent) -> Void) { self.callback = callback }
    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?) async throws { lock.withLock { turnTexts.append(text) } }
    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?, attachments: [StagedAgentAttachment]) async throws {
        lock.withLock { turnTexts.append(text) }
    }
    func steer(text: String, attachments: [StagedAgentAttachment]) async throws { lock.withLock { followUps.append(text) } }
    func approve(request: String, allow: Bool) async throws {}
    func setAccess(_ mode: AgentAccessMode) async throws {}
    func interrupt() async throws { callback(.status(.idle)) }
    func stop() {}
}

final class ComposerRuntimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ComposerFakeRuntime?
    var runtime: ComposerFakeRuntime? { lock.withLock { value } }
    func install(_ runtime: ComposerFakeRuntime) { lock.withLock { value = runtime } }
}

/// Panes that observe a conversation's revisions, as a host's observation stream delivers them.
@MainActor
final class ComposerObservers {
    private var panes: [WeakPane] = []
    private struct WeakPane { weak var pane: AgentPaneController? }
    func add(_ pane: AgentPaneController) { panes.append(WeakPane(pane: pane)) }
    func changed(_ session: SessionId, _ revision: UInt64) {
        for entry in panes { entry.pane?.sessionChanged(session: session, revision: revision) }
    }
}

/// One real conversation server (AgentSessions with a fixture provider) in a temporary
/// store, and any number of panes talking to it, each like a separate client.
@MainActor
final class ComposerHarness {
    let root: URL
    let box = ComposerRuntimeBox()
    let sessions: AgentSessions
    let session = SessionId()
    let project = ProjectId()
    let observers = ComposerObservers()
    private var panes: [AgentPaneController] = []
    /// Throws for the next matching request without forwarding it, as a lost request.
    var failNext: ((AgentChatRequest) -> Bool)?
    /// Forwards the next matching request, then throws, as a lost reply.
    var dropNextReply: ((AgentChatRequest) -> Bool)?
    /// Answers matching requests as a server that predates them does.
    var unsupported: ((AgentChatRequest) -> Bool)?
    /// Runs after the server took a submission and before its reply returns.
    var afterSubmit: (() async -> Void)?
    var runtime: ComposerFakeRuntime? { box.runtime }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ac-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let box = box, observers = observers
        sessions = try AgentSessions(root: root.appendingPathComponent("s"), projectDirectory: { [root] _ in root.path },
            changed: { session, revision in Task { @MainActor in observers.changed(session, revision) } },
            factory: { _, _, _, callback in
                let runtime = ComposerFakeRuntime(callback); box.install(runtime); return runtime
            })
    }

    func tearDown() {
        for pane in panes { pane.dispose() }
        sessions.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    func route(_ request: AgentChatRequest) async throws -> AgentChatSnapshot {
        if let fail = failNext, fail(request) { failNext = nil; throw URLError(.networkConnectionLost) }
        if let unsupported, unsupported(request) { throw ErrorReply(code: .unsupported, message: "Unsupported request") }
        let reply = try await sessions.handle(request)
        if let drop = dropNextReply, drop(request) { dropNextReply = nil; throw URLError(.networkConnectionLost) }
        if case .submit = request, let hook = afterSubmit { afterSubmit = nil; await hook() }
        return reply
    }

    /// A client of the conversation, with its own draft file when `draft` is given.
    func pane(draft: URL? = nil) -> AgentPaneController {
        let sessions = sessions, session = session
        let pane = AgentPaneController(session: session, project: project, provider: .codex) { [weak self] request in
            guard let self else { throw CancellationError() }
            return try await self.route(request)
        }
        pane.conversationRequest = { try await sessions.conversation($0) }
        pane.surface.fetchAttachment = { item, descriptor in
            try await sessions.attachment(.init(session: session, item: item, attachment: descriptor.id)).attachment.data
        }
        if let draft { pane.configureDraftStore(draft); pane.configureStash(draftURL: draft) }
        observers.add(pane)
        panes.append(pane)
        return pane
    }

    func read() async throws -> AgentChatSnapshot { try await sessions.handle(.read(session: session)) }

    /// Waits for `predicate` on the server's snapshot.
    func settle(_ predicate: (AgentChatSnapshot) -> Bool) async throws -> AgentChatSnapshot {
        for _ in 0..<300 {
            let snapshot = try await read()
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AgentRuntimeError("The conversation did not settle")
    }

    /// Connects `pane` and starts a turn that keeps working.
    func startWorking(_ pane: AgentPaneController, text: String = "Start") async throws {
        pane.refresh()
        try await until { pane.snapshot != nil && !pane.restoringDraft }
        pane.surface.composer.string = text
        pane.send()
        _ = try await settle { $0.status == .working && $0.queuedPrompts?.isEmpty == true }
        try await until { pane.snapshot?.status == .working && pane.commandTask == nil }
    }

    /// Queues `text` from `pane` behind the working turn.
    func queue(_ text: String, from pane: AgentPaneController, attachments: [AgentDraftAttachment] = []) async throws -> AgentQueuedPrompt {
        pane.surface.composer.string = text
        pane.draftAttachments = attachments
        pane.send()
        let snapshot = try await settle { $0.queuedPrompts?.contains { $0.text == text } == true }
        try await until { pane.commandTask == nil && pane.snapshot?.queuedPrompts?.contains { $0.text == text } == true }
        return try XCTUnwrap(snapshot.queuedPrompts?.first { $0.text == text })
    }
}

extension ComposerHarness {
    static func until(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() {
            guard Date() < deadline else { XCTFail("Timed out", file: file, line: line); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func until(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await Self.until(predicate, file: file, line: line)
    }
}
