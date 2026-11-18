import AgentCore
import Foundation
import XCTest
@testable import AgentRuntime

/// A provider for restore tests: each turn runs `work` in its folder, names its provider
/// conversation and message as Claude does, and ends unless told to keep working.
final class RestoreTestRuntime: AgentSessionRuntime, @unchecked Sendable {
    let callback: @Sendable (AgentRuntimeEvent) -> Void
    let directory: String
    private let lock = NSLock()
    private var turns = 0
    private var holding = false
    private var launched: [AgentLaunch] = []
    private var sentTexts: [String] = []
    var work: @Sendable (String, Int) throws -> Void

    init(directory: String, callback: @escaping @Sendable (AgentRuntimeEvent) -> Void,
         work: @escaping @Sendable (String, Int) throws -> Void) {
        self.directory = directory
        self.callback = callback
        self.work = work
    }

    /// Turns stay working until `finishTurn`.
    var holdsTurns: Bool {
        get { lock.withLock { holding } }
        set { lock.withLock { holding = newValue } }
    }
    var launches: [AgentLaunch] { lock.withLock { launched } }
    var sent: [String] { lock.withLock { sentTexts } }

    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?) async throws {
        let number = lock.withLock { () -> Int in
            turns += 1
            sentTexts.append(text)
            return turns
        }
        callback(.providerSession("provider-session"))
        try work(text, number)
        callback(.providerMessage("message-\(number)"))
        if !holdsTurns { callback(.status(.idle)) }
    }
    func finishTurn() { callback(.status(.idle)) }
    func prepare(_ launch: AgentLaunch) { lock.withLock { launched.append(launch) } }
    func approve(request: String, allow: Bool) async throws {}
    func setAccess(_ mode: AgentAccessMode) async throws {}
    func interrupt() async throws { callback(.status(.idle)) }
    func stop() {}
}

/// The runtimes a store started, newest last, by the folder each runs in.
final class RestoreTestRuntimes: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [RestoreTestRuntime] = []
    var all: [RestoreTestRuntime] { lock.withLock { started } }
    func append(_ runtime: RestoreTestRuntime) { lock.withLock { started.append(runtime) } }
    func last(in directory: String) -> RestoreTestRuntime? { all.last { $0.directory == directory } }
}

/// What restore tests share: a store root, conversations made in real Git folders, and waits.
class AgentRestoreTestCase: XCTestCase {
    func storeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-restore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// Sessions whose conversations work in `directory(project)`, each turn running `work`.
    func sessions(root: URL, runtimes: RestoreTestRuntimes, checkpoints: AgentCheckpointStore = AgentCheckpointStore(),
                  directory: @escaping @Sendable (ProjectId) -> String,
                  work: @escaping @Sendable (String, String, Int) throws -> Void) throws -> AgentSessions {
        try AgentSessions(root: root, projectDirectory: { directory($0) }, checkpoints: checkpoints) { _, folder, _, callback in
            let runtime = RestoreTestRuntime(directory: folder, callback: callback) { text, turn in try work(folder, text, turn) }
            runtimes.append(runtime)
            return runtime
        }
    }

    func waitFor(_ sessions: AgentSessions, _ id: SessionId, timeout: TimeInterval = 10,
                 until predicate: (AgentChatSnapshot) -> Bool) async throws -> AgentChatSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let snapshot = try await sessions.handle(.read(session: id))
            if predicate(snapshot) { return snapshot }
            guard Date() < deadline else { throw AgentRuntimeError("The conversation did not settle") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitUntil(_ timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw AgentRuntimeError("Condition not met") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Sends `text` and waits until its turn's changes are recorded.
    @discardableResult
    func turn(_ sessions: AgentSessions, _ id: SessionId, _ text: String) async throws -> AgentChatSnapshot {
        let before = try await sessions.handle(.read(session: id)).turns?.count ?? 0
        _ = try await sessions.handle(.send(session: id, text: text, model: nil))
        return try await waitFor(sessions, id) {
            $0.status == .idle && ($0.turns?.count ?? 0) == before + 1 && $0.turns?.last?.checkpointStatus?.state != .capturing
        }
    }

    /// Sends `text` and returns the checkpoint its turn recorded.
    func checkpoint(_ sessions: AgentSessions, _ id: SessionId, _ text: String) async throws -> String {
        let done = try await turn(sessions, id, text)
        return try XCTUnwrap(done.turns?.last?.checkpoint?.id)
    }

    func revert(_ sessions: AgentSessions, _ id: SessionId, _ checkpoint: String, paths: [String]? = nil,
                force: Bool = true) async throws -> AgentRevertReply {
        guard case .revert(let reply) = try await sessions.conversation(.revert(session: id, checkpoint: checkpoint, paths: paths, force: force)) else {
            throw AgentRuntimeError("Unexpected reply")
        }
        return reply
    }

    func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    func message(_ error: Error) -> String? {
        (error as? AgentRuntimeError)?.message ?? (error as? ServiceError)?.message ?? (error as? LocalizedError)?.errorDescription
    }

    /// A Git that holds every blob read until `gate` exists, saying it started at `began`.
    func gatedGit(in tools: URL) throws -> (git: GitCommand, began: URL, gate: URL) {
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let began = tools.appendingPathComponent("began"), gate = tools.appendingPathComponent("gate")
        let git = try AgentCheckpointTests.git("""
            for a in "$@"; do
              if [ "$a" = cat-file ]; then touch '\(began.path)'; while [ ! -f '\(gate.path)' ]; do sleep 0.05; done; fi
            done
            """, in: tools)
        return (git, began, gate)
    }
}
