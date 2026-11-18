import AgentCore
import Foundation
import XCTest
@testable import AgentRuntime

/// Edit from Here rewinds a conversation to before one of its messages: the whole
/// conversation is kept as an archive, the provider continues from the message before, and
/// files are put back only when asked and every removed turn has a checkpoint. A refusal or
/// failure leaves transcript, provider context and files as they were, or says what changed.
final class AgentRewindTests: AgentRestoreTestCase {
    private func rewind(_ sessions: AgentSessions, _ id: SessionId, at: String, archive: SessionId = SessionId(),
                        revision: UInt64, restoreFiles: Bool, force: Bool = false) async throws -> AgentRewindReply {
        guard case .rewound(let reply) = try await sessions.conversation(.rewind(session: id, at: at, archive: archive, revision: revision,
                                                                                 restoreFiles: restoreFiles, force: force)) else {
            throw AgentRuntimeError("Unexpected reply")
        }
        return reply
    }

    /// Three turns in a repository, each writing `<turn>.txt` and editing `shared.txt`.
    private func conversation(_ root: URL, runtimes: RestoreTestRuntimes, store: AgentCheckpointStore = AgentCheckpointStore(),
                              provider: AgentChatProvider = .claude) async throws
        -> (sessions: AgentSessions, id: SessionId, repo: GitTestRepo, snapshot: AgentChatSnapshot) {
        let repo = try GitTestRepo(commit: false)
        try repo.write("shared.txt", "original\n")
        try repo.commit("initial")
        let directory = repo.path
        let sessions = try sessions(root: root, runtimes: runtimes, checkpoints: store, directory: { _ in directory }) { folder, text, _ in
            try (text + "\n").write(toFile: folder + "/" + text + ".txt", atomically: true, encoding: .utf8)
            try ("by " + text + "\n").write(toFile: folder + "/shared.txt", atomically: true, encoding: .utf8)
        }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: provider))
        var snapshot: AgentChatSnapshot?
        for text in ["one", "two", "three"] { snapshot = try await turn(sessions, id, text) }
        return (sessions, id, repo, try XCTUnwrap(snapshot))
    }

    private func user(_ snapshot: AgentChatSnapshot, _ text: String) throws -> String {
        try XCTUnwrap(snapshot.items.first { $0.kind == .user && $0.text == text }?.id)
    }

    /// Keeping files, the conversation holds what came before the message, the archive holds
    /// it all, and the next message forks the provider at the message before.
    func testRewindKeepingFilesArchivesTheConversationAndContinuesFromTheMessageBefore() async throws {
        let root = try storeRoot(), runtimes = RestoreTestRuntimes()
        let (sessions, id, repo, before) = try await conversation(root, runtimes: runtimes)
        defer { sessions.shutdown() }
        XCTAssertEqual(before.turns?.map(\.rewindable), [true, true, true])
        let archive = SessionId()
        let reply = try await rewind(sessions, id, at: try user(before, "two"), archive: archive, revision: before.revision, restoreFiles: false)
        let rewound = try XCTUnwrap(reply.snapshot)
        XCTAssertEqual(rewound.items.filter { $0.kind == .user }.map(\.text), ["one"])
        XCTAssertEqual(rewound.items.last?.text, "Rewound to before a message. The full conversation is kept in history.")
        XCTAssertEqual(rewound.turns?.count, 1)
        XCTAssertNotNil(rewound.turns?.first?.checkpoint, "Kept turns keep their checkpoints")
        XCTAssertEqual(rewound.resetID, archive)
        XCTAssertEqual(rewound.providerSession, "provider-session")
        XCTAssertEqual(reply.files, AgentRevertReply())
        XCTAssertEqual(read(repo.path + "/three.txt"), "three\n", "Files stay as they are")

        let archived = try await sessions.handle(.read(session: archive))
        XCTAssertEqual(archived.items.filter { $0.kind == .user }.map(\.text), ["one", "two", "three"])
        XCTAssertEqual(archived.status, .closed)
        let removedCheckpoint = try XCTUnwrap(archived.turns?.last?.checkpoint?.id)
        let page = try await sessions.checkpoint(AgentCheckpointRequest(session: archive, checkpoint: removedCheckpoint))
        XCTAssertEqual(Set(page.files.map(\.path)), ["three.txt", "shared.txt"], "The archive owns the removed turns' checkpoints")

        _ = try await turn(sessions, id, "again")
        let launch = try XCTUnwrap(runtimes.all.last?.launches.last)
        XCTAssertEqual(launch.forkSource, "provider-session")
        XCTAssertEqual(launch.forkPoint, "message-1", "The provider continues from the reply before the message")
    }

    func testRewindRestoringFilesPutsBackEveryRemovedTurnsFilesAndSurvivesRestart() async throws {
        let root = try storeRoot(), runtimes = RestoreTestRuntimes()
        let (sessions, id, repo, before) = try await conversation(root, runtimes: runtimes)
        try repo.write("unrelated.txt", "mine\n")
        let archive = SessionId()
        let reply = try await rewind(sessions, id, at: try user(before, "two"), archive: archive, revision: before.revision, restoreFiles: true)
        XCTAssertEqual(Set(reply.files.reverted), ["two.txt", "shared.txt", "three.txt"])
        XCTAssertEqual(read(repo.path + "/shared.txt"), "by one\n", "As before the message")
        XCTAssertNil(read(repo.path + "/two.txt"))
        XCTAssertNil(read(repo.path + "/three.txt"))
        XCTAssertEqual(read(repo.path + "/one.txt"), "one\n")
        XCTAssertEqual(read(repo.path + "/unrelated.txt"), "mine\n")
        XCTAssertTrue(reply.snapshot?.items.last?.text.contains("restored 3 files") == true)
        let kept = try XCTUnwrap(reply.snapshot?.turns?.first?.checkpoint?.id)
        sessions.shutdown()

        let restarted = try self.sessions(root: root, runtimes: runtimes, directory: { _ in repo.path }) { _, _, _ in }
        defer { restarted.shutdown() }
        let live = try await restarted.handle(.read(session: id))
        XCTAssertEqual(live.turns?.first?.checkpoint?.id, kept)
        let keptPage = try await restarted.checkpoint(AgentCheckpointRequest(session: id, checkpoint: kept))
        XCTAssertEqual(Set(keptPage.files.map(\.path)), ["one.txt", "shared.txt"])
        let archived = try await restarted.handle(.read(session: archive))
        let removed = try XCTUnwrap(archived.turns?.last?.checkpoint?.id)
        let removedPage = try await restarted.checkpoint(AgentCheckpointRequest(session: archive, checkpoint: removed, path: "three.txt"))
        XCTAssertEqual(removedPage.diff?.additions, 1, "The archive's checkpoint refs survived")
    }

    /// Files changed after the removed turns stop a restoring rewind, changing nothing, until forced.
    func testRewindRefusesLaterEditsUnlessForced() async throws {
        let root = try storeRoot(), runtimes = RestoreTestRuntimes()
        let (sessions, id, repo, before) = try await conversation(root, runtimes: runtimes)
        defer { sessions.shutdown() }
        try repo.write("shared.txt", "my own edit\n")
        let at = try user(before, "two")
        let refused = try await rewind(sessions, id, at: at, revision: before.revision, restoreFiles: true)
        XCTAssertNil(refused.snapshot)
        XCTAssertEqual(refused.files.conflicts, ["shared.txt"])
        let unchanged = try await sessions.handle(.read(session: id))
        XCTAssertEqual(unchanged.revision, before.revision, "The conversation is as it was")
        XCTAssertEqual(read(repo.path + "/three.txt"), "three\n")
        XCTAssertEqual(read(repo.path + "/shared.txt"), "my own edit\n")
        let forced = try await rewind(sessions, id, at: at, revision: before.revision, restoreFiles: true, force: true)
        XCTAssertNotNil(forced.snapshot)
        XCTAssertEqual(read(repo.path + "/shared.txt"), "by one\n")
    }

    /// Nothing changes when the provider can't continue from an earlier message, a removed
    /// turn has no checkpoint, the conversation moved on, or a client cancels by not asking.
    func testUnsupportedProvidersMissingCheckpointsAndStaleRevisionsChangeNothing() async throws {
        let root = try storeRoot(), runtimes = RestoreTestRuntimes()
        let (codex, codexID, codexRepo, codexSnapshot) = try await conversation(root, runtimes: runtimes, provider: .codex)
        defer { codex.shutdown() }
        defer { withExtendedLifetime(codexRepo) {} }
        XCTAssertEqual(codexSnapshot.turns?.map(\.rewindable), [false, false, false])
        do {
            _ = try await rewind(codex, codexID, at: try user(codexSnapshot, "two"), revision: codexSnapshot.revision, restoreFiles: false)
            XCTFail("Codex can't continue from an earlier message")
        } catch {
            XCTAssertEqual(message(error), "Codex can't continue from an earlier message. Use Edit as New Prompt or start a new conversation.")
        }
        let codexAfter = try await codex.handle(.read(session: codexID))
        XCTAssertEqual(codexAfter.revision, codexSnapshot.revision)

        let otherRoot = try storeRoot()
        let (sessions, id, repo, before) = try await conversation(otherRoot, runtimes: runtimes)
        defer { sessions.shutdown() }
        do {
            _ = try await rewind(sessions, id, at: try user(before, "two"), revision: before.revision - 1, restoreFiles: false)
            XCTFail("A stale revision is refused")
        } catch {
            XCTAssertEqual(message(error), "The conversation changed. Review it before editing from here.")
        }
        // A turn whose changes weren't recorded can't have its files restored.
        sessions.capturesCheckpoints = false
        let unrecorded = try await turn(sessions, id, "four")
        do {
            _ = try await rewind(sessions, id, at: try user(unrecorded, "three"), revision: unrecorded.revision, restoreFiles: true)
            XCTFail("No checkpoint, no restore")
        } catch {
            XCTAssertEqual(message(error), "Turn 4 has no recorded file changes, so files can't be restored. Rewind and keep the files instead.")
        }
        XCTAssertEqual(read(repo.path + "/four.txt"), "four\n")
        let afterRefusal = try await sessions.handle(.read(session: id))
        XCTAssertEqual(afterRefusal.revision, unrecorded.revision)
    }

    /// A restore that fails part way leaves the conversation whole and its files as they
    /// were; the folder's reservation is released.
    func testAFailureDuringRestoreLeavesTheConversationAndFiles() async throws {
        let root = try storeRoot(), runtimes = RestoreTestRuntimes(), failing = CompletionFlag()
        var store = AgentCheckpointStore()
        store.willRestore = { path in if failing.isSet, path == "three.txt" { throw AgentRuntimeError("disk full") } }
        let (sessions, id, repo, before) = try await conversation(root, runtimes: runtimes, store: store)
        defer { sessions.shutdown() }
        failing.set()
        do {
            _ = try await rewind(sessions, id, at: try user(before, "two"), revision: before.revision, restoreFiles: true)
            XCTFail("The restore fails")
        } catch {
            XCTAssertEqual(message(error), "Couldn't restore three.txt: disk full No files were changed.")
        }
        let after = try await sessions.handle(.read(session: id))
        XCTAssertEqual(after.revision, before.revision)
        XCTAssertEqual(after.items.count, before.items.count)
        for name in ["two", "three"] { XCTAssertEqual(read(repo.path + "/\(name).txt"), name + "\n") }
        XCTAssertEqual(read(repo.path + "/shared.txt"), "by three\n")
        failing.clear()
        let reply = try await rewind(sessions, id, at: try user(before, "two"), revision: before.revision, restoreFiles: true)
        XCTAssertNotNil(reply.snapshot, "Nothing was left reserved")
    }

    /// A rewind holds the conversation: a message sent meanwhile is refused, not sent to the
    /// agent, and a clear waits for it to finish.
    func testARewindHoldsTheConversationWhileItRestores() async throws {
        let root = try storeRoot(), runtimes = RestoreTestRuntimes()
        let (gated, began, gate) = try gatedGit(in: root.appendingPathComponent("tools"))
        defer { try? Data().write(to: gate) }
        let (sessions, id, repo, before) = try await conversation(root, runtimes: runtimes, store: AgentCheckpointStore(git: gated))
        defer { sessions.shutdown() }
        defer { withExtendedLifetime(repo) {} }
        let at = try user(before, "three")
        let rewinding = Task { try await self.rewind(sessions, id, at: at, revision: before.revision, restoreFiles: true) }
        try await waitUntil { FileManager.default.fileExists(atPath: began.path) }
        do {
            _ = try await sessions.handle(.send(session: id, text: "Meanwhile", model: nil))
            XCTFail("Held back")
        } catch {
            XCTAssertEqual(message(error), AgentRestoreWork.holdMessage)
        }
        // A clear waits for the conversation's checkpoint work, then finds it rewound.
        let clearing = Task { try await sessions.handle(.clear(session: id, archive: SessionId(), expectedRevision: before.revision)) }
        try Data().write(to: gate)
        let reply = try await rewinding.value
        do {
            _ = try await clearing.value
            XCTFail("The clear sees the rewound conversation")
        } catch {
            // Refused as the rewind commits, or once it has.
            XCTAssertTrue(["The conversation is being cleared. Try again shortly.",
                           "The conversation changed. Review it before clearing."].contains(message(error) ?? ""), "\(error)")
        }
        XCTAssertEqual(reply.snapshot?.items.filter { $0.kind == .user }.map(\.text), ["one", "two"])
        XCTAssertFalse(runtimes.all.contains { $0.sent.contains("Meanwhile") })
    }
}
