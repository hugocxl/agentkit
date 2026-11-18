import AgentCore
import Foundation
import XCTest
@testable import AgentRuntime

/// A restore is reserved against everything else that may change the same physical folder:
/// other conversations working there however its path is spelled, their agents, queued
/// prompts, and other restores. A refused restore changes no files, a successful one leaves
/// unrelated files and the real Git index alone, and one that fails part way puts back what
/// it changed or says exactly which files it couldn't.
final class AgentRestoreCoordinationTests: AgentRestoreTestCase {
    /// A folder `repo` holds two conversations in: one through a symbolic link to it.
    private func aliasedProjects(_ repo: GitTestRepo, root: URL) throws -> (ProjectId, ProjectId, String) {
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: repo.path)
        return (ProjectId(), ProjectId(), link.path)
    }

    func testARestoreLeavesUnrelatedFilesAndTheRealIndexAlone() async throws {
        let root = try storeRoot(), repo = try GitTestRepo(commit: false), runtimes = RestoreTestRuntimes()
        try repo.write("edited.txt", "original\n")
        try repo.write("unrelated.txt", "mine\n")
        try repo.commit("initial")
        try repo.write("staged.txt", "staged by the user\n")
        try repo.run("add", "staged.txt")
        let directory = repo.path
        let sessions = try sessions(root: root, runtimes: runtimes, directory: { _ in directory }) { folder, _, _ in
            try "agent\n".write(toFile: folder + "/edited.txt", atomically: true, encoding: .utf8)
            try "new\n".write(toFile: folder + "/added.txt", atomically: true, encoding: .utf8)
        }
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        let done = try await turn(sessions, id, "Edit")
        let checkpoint = try XCTUnwrap(done.turns?.last?.checkpoint?.id)
        try "mine, edited later\n".write(toFile: directory + "/unrelated.txt", atomically: true, encoding: .utf8)
        let indexPath = try repo.run("rev-parse", "--path-format=absolute", "--git-path", "index").trimmingCharacters(in: .whitespacesAndNewlines)
        let index = try Data(contentsOf: URL(fileURLWithPath: indexPath))
        let staged = try repo.run("diff", "--cached", "--name-only")

        let reply = try await revert(sessions, id, checkpoint, force: false)
        XCTAssertEqual(Set(reply.reverted), ["edited.txt", "added.txt"])
        XCTAssertEqual(read(directory + "/edited.txt"), "original\n")
        XCTAssertNil(read(directory + "/added.txt"))
        XCTAssertEqual(read(directory + "/unrelated.txt"), "mine, edited later\n", "Files the turn didn't change stay")
        XCTAssertEqual(read(directory + "/staged.txt"), "staged by the user\n")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: indexPath)), index, "The real index is untouched")
        XCTAssertEqual(try repo.run("diff", "--cached", "--name-only"), staged)
    }

    /// Another conversation working in the same folder, reached through another path, holds a
    /// revert back; once it is done the revert applies.
    func testAnotherConversationWorkingInTheSameFolderRefusesARestore() async throws {
        let root = try storeRoot(), repo = try GitTestRepo(commit: false), runtimes = RestoreTestRuntimes()
        try repo.write("file.txt", "before\n")
        try repo.commit("initial")
        let (aliased, real, link) = try aliasedProjects(repo, root: root)
        let directory = repo.path
        let sessions = try sessions(root: root, runtimes: runtimes, directory: { $0 == aliased ? link : directory }) { _, text, _ in
            guard text == "Edit" else { return }
            try "after\n".write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8)
        }
        defer { sessions.shutdown() }
        let owner = SessionId(), other = SessionId()
        _ = try await sessions.handle(.create(session: owner, project: real, provider: .claude))
        _ = try await sessions.handle(.create(session: other, project: aliased, provider: .claude))
        let checkpoint = try await checkpoint(sessions, owner, "Edit")
        // The other conversation starts a turn that keeps working.
        _ = try await sessions.handle(.send(session: other, text: "Warm up", model: nil))
        _ = try await waitFor(sessions, other) { $0.status == .idle }
        let worker = try XCTUnwrap(runtimes.last(in: link))
        worker.holdsTurns = true
        _ = try await sessions.handle(.send(session: other, text: "Work", model: nil))
        _ = try await waitFor(sessions, other) { $0.status == .working }
        do {
            _ = try await revert(sessions, owner, checkpoint)
            XCTFail("Refused while another conversation works in the folder")
        } catch {
            XCTAssertEqual(message(error), "An agent in another conversation is working in this folder. Wait for it to finish or stop it first.")
        }
        XCTAssertEqual(read(directory + "/file.txt"), "after\n", "A refused restore changes nothing")
        worker.finishTurn()
        _ = try await waitFor(sessions, other) { $0.status == .idle && $0.turns?.last?.checkpointStatus?.state != .capturing }
        let reply = try await revert(sessions, owner, checkpoint)
        XCTAssertEqual(reply.reverted, ["file.txt"])
        XCTAssertEqual(read(directory + "/file.txt"), "before\n")
    }

    /// An agent still running under an idle parent may change files: its own conversation's
    /// revert is refused, and so is one of another conversation in the same folder.
    func testAnActiveChildUnderAnIdleParentHoldsRestores() async throws {
        let root = try storeRoot(), repo = try GitTestRepo(commit: false), runtimes = RestoreTestRuntimes()
        try repo.write("file.txt", "before\n")
        try repo.commit("initial")
        let directory = repo.path
        let sessions = try sessions(root: root, runtimes: runtimes, directory: { _ in directory }) { folder, text, _ in
            guard text == "Edit" else { return }
            try "after\n".write(toFile: folder + "/file.txt", atomically: true, encoding: .utf8)
        }
        defer { sessions.shutdown() }
        let owner = SessionId(), parent = SessionId()
        _ = try await sessions.handle(.create(session: owner, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.create(session: parent, project: ProjectId(), provider: .claude))
        let checkpoint = try await checkpoint(sessions, owner, "Edit")
        _ = try await turn(sessions, parent, "Start an agent")
        let child = try XCTUnwrap(runtimes.all.last)
        child.callback(.subagents([AgentSubagent(id: "a1", toolUseID: "task", description: "Edit in the background", background: true)]))
        _ = try await waitFor(sessions, parent) { $0.status == .idle && $0.subagents?.first?.status == .running }
        do {
            _ = try await revert(sessions, owner, checkpoint)
            XCTFail("Refused while another conversation's agent runs in the folder")
        } catch {
            XCTAssertEqual(message(error), "Agents of another conversation are running in this folder. Wait for them or stop them first.")
        }
        XCTAssertEqual(read(directory + "/file.txt"), "after\n")

        // The owner's own child, under its idle parent, holds it the same way.
        child.callback(.subagents([AgentSubagent(id: "a1", toolUseID: "task", description: "Edit in the background",
                                                 background: true, status: .completed)]))
        _ = try await waitFor(sessions, parent) { $0.subagents?.first?.status == .completed }
        let ownRuntime = try XCTUnwrap(runtimes.all.first)
        ownRuntime.callback(.subagents([AgentSubagent(id: "b1", toolUseID: "task2", description: "Own child", background: true)]))
        _ = try await waitFor(sessions, owner) { $0.status == .idle && $0.subagents?.first?.status == .running }
        do {
            _ = try await revert(sessions, owner, checkpoint)
            XCTFail("Refused while its own agent runs")
        } catch {
            XCTAssertEqual(message(error), "Stop active work before reverting.")
        }
        XCTAssertEqual(read(directory + "/file.txt"), "after\n")
    }

    /// A message sent to another conversation in the folder while a restore is applied is
    /// refused without reaching its agent, and a prompt queued there waits for the restore,
    /// then is delivered once.
    func testWorkAskedForDuringARestoreInTheSameFolderWaitsForIt() async throws {
        let root = try storeRoot(), repo = try GitTestRepo(commit: false), runtimes = RestoreTestRuntimes()
        try repo.write("file.txt", "before\n")
        try repo.commit("initial")
        let (gated, began, gate) = try gatedGit(in: root.appendingPathComponent("tools"))
        defer { try? Data().write(to: gate) }
        let (aliased, real, link) = try aliasedProjects(repo, root: root)
        let directory = repo.path
        let sessions = try sessions(root: root, runtimes: runtimes, checkpoints: AgentCheckpointStore(git: gated),
                                    directory: { $0 == aliased ? link : directory }) { _, text, _ in
            try (text + "\n").write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8)
        }
        defer { sessions.shutdown() }
        let owner = SessionId(), other = SessionId()
        _ = try await sessions.handle(.create(session: owner, project: real, provider: .claude))
        _ = try await sessions.handle(.create(session: other, project: aliased, provider: .claude))
        let checkpoint = try await checkpoint(sessions, owner, "Edit")

        let reverting = Task { try await self.revert(sessions, owner, checkpoint) }
        try await waitUntil { FileManager.default.fileExists(atPath: began.path) }
        do {
            _ = try await sessions.handle(.send(session: other, text: "Overwrite", model: nil))
            XCTFail("A message during the restore is held back")
        } catch {
            XCTAssertEqual(message(error), AgentRestoreWork.holdMessage)
        }
        let prompt = AgentPrompt(text: "Queued", model: nil, effort: nil, provider: .claude, planMode: false)
        _ = try await sessions.handle(.submit(session: other, prompt: prompt))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(runtimes.last(in: link), "Nothing reached the other conversation's agent")
        let waiting = try await sessions.handle(.read(session: other))
        XCTAssertEqual(waiting.queuedPrompts?.map(\.state), [.queued])

        try Data().write(to: gate)
        let reply = try await reverting.value
        XCTAssertEqual(reply.reverted, ["file.txt"])
        let delivered = try await waitFor(sessions, other) { $0.status == .idle && $0.queuedPrompts?.isEmpty != false && $0.turns?.count == 1 }
        XCTAssertEqual(runtimes.last(in: link)?.sent, ["Queued"], "Delivered once, after the restore")
        XCTAssertEqual(read(directory + "/file.txt"), "Queued\n", "The later turn's work stays")
        XCTAssertNotEqual(delivered.queuePaused, true, "The queue never paused for the restore")
    }

    /// Two restores never change the same folder at once, whichever conversation or client
    /// asks; a second client confirming the same revert afterwards finds it done.
    func testCompetingRestoresAndASecondConfirmingClient() async throws {
        let root = try storeRoot(), repo = try GitTestRepo(commit: false), runtimes = RestoreTestRuntimes()
        try repo.write("a.txt", "a\n")
        try repo.write("b.txt", "b\n")
        try repo.commit("initial")
        let (gated, began, gate) = try gatedGit(in: root.appendingPathComponent("tools"))
        defer { try? Data().write(to: gate) }
        let (aliased, real, link) = try aliasedProjects(repo, root: root)
        let directory = repo.path
        let sessions = try sessions(root: root, runtimes: runtimes, checkpoints: AgentCheckpointStore(git: gated),
                                    directory: { $0 == aliased ? link : directory }) { _, text, _ in
            try "changed\n".write(toFile: directory + "/" + text, atomically: true, encoding: .utf8)
        }
        defer { sessions.shutdown() }
        let first = SessionId(), second = SessionId()
        _ = try await sessions.handle(.create(session: first, project: real, provider: .claude))
        _ = try await sessions.handle(.create(session: second, project: aliased, provider: .claude))
        let firstCheckpoint = try await checkpoint(sessions, first, "a.txt")
        let secondCheckpoint = try await checkpoint(sessions, second, "b.txt")

        let applying = Task { try await self.revert(sessions, first, firstCheckpoint) }
        try await waitUntil { FileManager.default.fileExists(atPath: began.path) }
        for (session, checkpoint) in [(first, firstCheckpoint), (second, secondCheckpoint)] {
            do {
                _ = try await revert(sessions, session, checkpoint)
                XCTFail("A competing restore is refused")
            } catch {
                XCTAssertEqual(message(error), "Another revert is being applied in this folder. Try again when it finishes.")
            }
        }
        XCTAssertEqual(read(directory + "/b.txt"), "changed\n", "The refused restore changed nothing")
        try Data().write(to: gate)
        let applied = try await applying.value
        XCTAssertEqual(applied.reverted, ["a.txt"])

        // A second client confirms the same revert after the first applied it.
        let again = try await revert(sessions, first, firstCheckpoint, force: false)
        XCTAssertEqual(again.reverted, [])
        XCTAssertEqual(again.conflicts, [])
        XCTAssertEqual(again.unchanged, ["a.txt"])
        XCTAssertEqual(read(directory + "/a.txt"), "a\n")
        let other = try await revert(sessions, second, secondCheckpoint)
        XCTAssertEqual(other.reverted, ["b.txt"])
    }

    /// A restore that fails part way puts back every file it had changed, and says which
    /// file stopped it; files it couldn't put back are named, and the conversation says so.
    func testAFailureMidRestoreRollsBackOrReportsExactlyWhatChanged() async throws {
        let repo = try GitTestRepo(commit: false)
        try repo.write("one/a.txt", "a\n")
        try repo.write("two/b.txt", "b\n")
        try repo.write("c.txt", "c\n")
        try repo.commit("initial")
        var store = AgentCheckpointStore()
        let before = try store.capture(directory: repo.path)
        for path in ["one/a.txt", "two/b.txt", "c.txt"] { try repo.write(path, "agent\n") }
        let after = try store.capture(directory: repo.path)
        addTeardownBlock { [store] in try? store.remove(before); try? store.remove(after) }
        let paths = try store.files(from: before, to: after).map(\.path)
        XCTAssertEqual(paths, ["c.txt", "one/a.txt", "two/b.txt"])

        store.willRestore = { path in if path == "two/b.txt" { throw AgentRuntimeError("disk full") } }
        XCTAssertThrowsError(try store.restore(before, paths: paths)) { error in
            XCTAssertEqual(error as? AgentRestoreFailure,
                           AgentRestoreFailure(path: "two/b.txt", reason: "disk full", rolledBack: ["c.txt", "one/a.txt"], changed: []))
            XCTAssertTrue((error as? AgentRestoreFailure)?.errorDescription?.hasSuffix("No files were changed.") == true)
        }
        for path in paths { XCTAssertEqual(read(repo.path + "/" + path), "agent\n", "\(path) is as it was") }

        // A file already restored whose folder can no longer be written can't be put back.
        let locked = repo.path + "/one"
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        store.willRestore = { path in
            guard path == "two/b.txt" else { return }
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked)
            throw AgentRuntimeError("disk full")
        }
        XCTAssertThrowsError(try store.restore(before, paths: paths)) { error in
            let failure = error as? AgentRestoreFailure
            XCTAssertEqual(failure?.changed, ["one/a.txt"])
            XCTAssertEqual(failure?.rolledBack, ["c.txt"])
            XCTAssertTrue(failure?.errorDescription?.contains("couldn't be put back: one/a.txt") == true)
        }
        XCTAssertEqual(read(repo.path + "/one/a.txt"), "a\n", "Left restored, and said so")
        XCTAssertEqual(read(repo.path + "/c.txt"), "agent\n")
        XCTAssertEqual(read(repo.path + "/two/b.txt"), "agent\n")
    }

    /// Through a conversation, a failed restore reaches the client with the file that stopped
    /// it, changes nothing it could put back, and leaves the reservation free.
    func testAConversationsFailedRestoreSaysWhyAndFreesTheFolder() async throws {
        let root = try storeRoot(), repo = try GitTestRepo(commit: false), runtimes = RestoreTestRuntimes()
        try repo.write("a.txt", "a\n")
        try repo.write("b.txt", "b\n")
        try repo.commit("initial")
        let directory = repo.path, failing = CompletionFlag()
        failing.set()
        var store = AgentCheckpointStore()
        store.willRestore = { path in if path == "b.txt", failing.isSet { throw AgentRuntimeError("disk full") } }
        let sessions = try sessions(root: root, runtimes: runtimes, checkpoints: store, directory: { _ in directory }) { folder, _, _ in
            for name in ["a.txt", "b.txt"] { try "agent\n".write(toFile: folder + "/" + name, atomically: true, encoding: .utf8) }
        }
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        let checkpoint = try await checkpoint(sessions, id, "Edit")
        do {
            _ = try await revert(sessions, id, checkpoint)
            XCTFail("The restore fails")
        } catch {
            XCTAssertEqual(message(error), "Couldn't restore b.txt: disk full No files were changed.")
        }
        XCTAssertEqual(read(directory + "/a.txt"), "agent\n")
        XCTAssertEqual(read(directory + "/b.txt"), "agent\n")
        failing.clear()
        let retried = try await revert(sessions, id, checkpoint)
        XCTAssertEqual(Set(retried.reverted), ["a.txt", "b.txt"], "The folder is free again")
    }
}
