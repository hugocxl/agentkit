import AgentCore
import Foundation
import XCTest
@testable import AgentRuntime

final class AgentCheckpointTests: XCTestCase {
    func testCapturesNetTurnChangesWithoutTouchingIndexOrBranch() throws {
        let repo = try GitTestRepo(commit: false)
        try repo.write("file.txt", "original\n")
        try repo.commit("initial")
        try repo.write("file.txt", "staged\n")
        try repo.run("add", "file.txt")
        try repo.write("file.txt", "before turn\n")
        let indexPath = try repo.run("rev-parse", "--path-format=absolute", "--git-path", "index").trimmingCharacters(in: .whitespacesAndNewlines)
        let index = try Data(contentsOf: URL(fileURLWithPath: indexPath))
        let head = try repo.run("rev-parse", "HEAD")
        let store = AgentCheckpointStore()
        let before = try store.capture(directory: repo.path)
        defer { try? store.remove(before) }
        try repo.write("file.txt", "intermediate edit\n")
        try repo.write("file.txt", "after turn\n")
        let after = try store.capture(directory: repo.path)
        defer { try? store.remove(after) }
        let change = try XCTUnwrap(store.files(from: before, to: after).first)
        XCTAssertEqual(change.path, "file.txt")
        XCTAssertEqual(change.additions, 1)
        XCTAssertEqual(change.deletions, 1)
        let diff = try store.diff(from: before, to: after, path: change.path)
        XCTAssertTrue(diff.rows.contains { $0.text == "-before turn" })
        XCTAssertTrue(diff.rows.contains { $0.text == "+after turn" })
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: indexPath)), index)
        XCTAssertEqual(try repo.run("rev-parse", "HEAD"), head)
        XCTAssertEqual(try repo.run("show", ":file.txt"), "staged\n")
    }

    func testRevertedEditsDisappearAndUntrackedNamesRemainExact() throws {
        let repo = try GitTestRepo(commit: false)
        try repo.write("file", "same\n")
        try repo.commit("initial")
        let store = AgentCheckpointStore()
        let before = try store.capture(directory: repo.path)
        defer { try? store.remove(before) }
        try repo.write("file", "temporary\n")
        try repo.write("file", "same\n")
        let name = "new [*]\nfile.txt"
        try repo.write(name, "new\n")
        let after = try store.capture(directory: repo.path)
        defer { try? store.remove(after) }
        let changes = try store.files(from: before, to: after)
        XCTAssertEqual(changes.map(\.path), [name])
        XCTAssertEqual(changes.first?.additions, 1)
    }

    /// A record naming a ref outside AgentKit's own leaves that ref alone, and isn't kept
    /// to be tried again: there is nothing of AgentKit's to remove.
    func testCleanupLeavesAnUnrelatedReferenceAlone() throws {
        let repo = try GitTestRepo(commit: true)
        let tree = try repo.run("rev-parse", "HEAD^{tree}").trimmingCharacters(in: .whitespacesAndNewlines)
        try repo.run("update-ref", "refs/keep/my-reference", tree)
        let forged = AgentCheckpointStore.Snapshot(tree: tree, reference: "refs/keep/my-reference", directory: repo.path)
        XCTAssertNoThrow(try AgentCheckpointStore().remove(forged))
        XCTAssertEqual(try repo.run("rev-parse", "refs/keep/my-reference").trimmingCharacters(in: .whitespacesAndNewlines), tree)
    }

    /// A checkpoint keeps its repository, so its ref is removed there once its folder is
    /// gone, as with a folder inside the repository or a removed worktree.
    func testRefsAreRemovedFromTheirRepositoryAfterTheirFolderIsGone() throws {
        let repo = try GitTestRepo(commit: true)
        let store = AgentCheckpointStore()
        try repo.write("sub/file.txt", "inside\n")
        let folder = repo.path + "/sub"
        let kept = try store.capture(directory: folder)
        XCTAssertNotNil(kept.repository)
        var older = try store.capture(directory: folder)
        older.repository = nil
        try FileManager.default.removeItem(atPath: folder)
        XCTAssertNoThrow(try store.remove(kept))
        XCTAssertNoThrow(try store.remove(older), "Without one, the nearest folder that remains finds the repository")
        for snapshot in [kept, older] {
            XCTAssertThrowsError(try repo.run("rev-parse", "--verify", "--quiet", snapshot.reference))
        }

        let worktree = repo.path + "-worktree"
        try repo.run("worktree", "add", "--detach", worktree)
        defer { try? FileManager.default.removeItem(atPath: worktree) }
        let linked = try store.capture(directory: worktree)
        try FileManager.default.removeItem(atPath: worktree)
        XCTAssertNoThrow(try store.remove(linked))
        XCTAssertThrowsError(try repo.run("rev-parse", "--verify", "--quiet", linked.reference),
                             "A worktree's refs live in the repository it shares")
    }

    /// A Git without `show-ref --exists`, as before 2.43.
    static let withoutExists = #"for a in "$@"; do [ "$a" = --exists ] && { echo "error: unknown option" >&2; exit 129; }; done"#

    /// A Git that runs `script` before the real one, as an older Git or a slow one.
    static func git(_ script: String, in folder: URL) throws -> GitCommand {
        let path = folder.appendingPathComponent("git")
        try ("#!/bin/sh\n" + script + "\nexec /usr/bin/git \"$@\"\n").write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return GitCommand(lookup: ExecutableLookup { $0 == "git" ? path.path : ExecutableLookup.system($0) })
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentkit-tools-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// A checkpoint's ref turned into a link to another checkpoint's goes alone: the one it
    /// links to keeps pinning its own tree.
    func testRemovingARefNeverFollowsItIntoAnotherCheckpoint() throws {
        let repo = try GitTestRepo(commit: true)
        let store = AgentCheckpointStore()
        let linked = try store.capture(directory: repo.path), other = try store.capture(directory: repo.path)
        XCTAssertEqual(linked.tree, other.tree, "Nothing changed between them")
        try repo.run("symbolic-ref", linked.reference, other.reference)
        XCTAssertNoThrow(try store.remove(linked))
        XCTAssertNoThrow(try repo.run("rev-parse", "--verify", other.reference), "The other checkpoint keeps its ref")
    }

    /// Git checks who owns a repository it finds, not one it is pointed at, so neither is
    /// one owned by someone else changed.
    func testARepositoryOwnedBySomeoneElseIsLeftAlone() throws {
        var owner = stat()
        try XCTSkipIf(stat("/usr/share", &owner) == 0 && owner.st_uid == geteuid(), "/usr/share is this user's")
        let theirs = AgentCheckpointStore.Snapshot(tree: String(repeating: "a", count: 40),
            reference: "refs/tab/checkpoints/" + UUID().uuidString.lowercased(), directory: "/usr/share", repository: "/usr/share")
        XCTAssertThrowsError(try AgentCheckpointStore().remove(theirs)) { error in
            XCTAssertTrue("\(error)".contains("isn't this user's"), "Refused before Git runs there: \(error)")
        }
    }

    /// A repository whose working tree setting leads to a folder that is gone, as a removed
    /// submodule's, still has its ref removed.
    func testRefsAreRemovedWhenTheWorkingTreeGitWouldEnterIsGone() throws {
        let repo = try GitTestRepo(commit: true)
        let snapshot = try AgentCheckpointStore().capture(directory: repo.path)
        let config = URL(fileURLWithPath: repo.path).appendingPathComponent(".git/config")
        let original = try String(contentsOf: config, encoding: .utf8)
        try repo.run("config", "core.worktree", "../gone-checkout")
        XCTAssertNoThrow(try AgentCheckpointStore().remove(snapshot))
        // Git can't run in the repository itself while that folder is gone.
        try original.write(to: config, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try repo.run("rev-parse", "--verify", "--quiet", snapshot.reference))
    }

    /// Git before 2.43 can't tell a missing ref from one it couldn't read; its ref files
    /// must show the ref is gone before the record goes.
    func testOlderGitNeedsTheRefFilesToShowARefIsGone() throws {
        let repo = try GitTestRepo(commit: true)
        let git = try Self.git(Self.withoutExists, in: try folder())
        let store = AgentCheckpointStore(git: git)
        let gone = try store.capture(directory: repo.path)
        try repo.run("update-ref", "-d", gone.reference)
        XCTAssertNoThrow(try store.remove(gone), "Neither a loose nor a packed ref: gone")

        let packed = try store.capture(directory: repo.path)
        try repo.run("pack-refs", "--all")
        let lock = URL(fileURLWithPath: repo.path).appendingPathComponent(".git/packed-refs.lock")
        try Data().write(to: lock)
        XCTAssertThrowsError(try store.remove(packed), "Still packed, and Git couldn't remove it yet")
        try FileManager.default.removeItem(at: lock)
        XCTAssertNoThrow(try store.remove(packed))
        XCTAssertThrowsError(try repo.run("rev-parse", "--verify", "--quiet", packed.reference))
    }

    /// A worktree whose own folder in its repository was pruned still leads back to that
    /// repository, where its refs are removed.
    func testAPrunedWorktreeLeadsBackToItsRepository() throws {
        let repo = try GitTestRepo(commit: true)
        let worktree = repo.path + "-pruned"
        try repo.run("worktree", "add", "--detach", worktree)
        defer { try? FileManager.default.removeItem(atPath: worktree) }
        var older = try AgentCheckpointStore().capture(directory: worktree)
        older.repository = nil
        let admin = URL(fileURLWithPath: repo.path).appendingPathComponent(".git/worktrees")
        let own = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: admin, includingPropertiesForKeys: nil).first)
        let link = try String(contentsOfFile: worktree + "/.git", encoding: .utf8)
        try (link.trimmingCharacters(in: .newlines) + "\r\n").write(toFile: worktree + "/.git", atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: own)
        XCTAssertNoThrow(try AgentCheckpointStore().remove(older))
        XCTAssertThrowsError(try repo.run("rev-parse", "--verify", "--quiet", older.reference))
    }

    /// A capture that can't find its repository fails before it makes a ref nothing could
    /// find again.
    func testACaptureThatCannotFindItsRepositoryMakesNoRef() throws {
        let repo = try GitTestRepo(commit: true)
        let git = try Self.git(#"for a in "$@"; do [ "$a" = --git-common-dir ] && exit 1; done"#, in: try folder())
        XCTAssertThrowsError(try AgentCheckpointStore(git: git).capture(directory: repo.path))
        XCTAssertEqual(try repo.run("for-each-ref", "refs/tab/checkpoints/").trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    /// A pin Git made before failing, as when its hook outlasted the time allowed, counts;
    /// one it may have made is removed; one it didn't make leaves nothing behind.
    func testACaptureWhosePinFailedLeavesNoRefItDoesNotTrack() throws {
        let repo = try GitTestRepo(commit: true)
        func refs() throws -> String { try repo.run("for-each-ref", "refs/tab/checkpoints/").trimmingCharacters(in: .whitespacesAndNewlines) }
        let madeThenFailed = AgentCheckpointStore(git: try Self.git(#"case "$*" in *"update-ref refs/tab"*) /usr/bin/git "$@"; echo "error: timed out" >&2; exit 1 ;; esac"#, in: try folder()))
        let kept = try madeThenFailed.capture(directory: repo.path)
        XCTAssertNoThrow(try repo.run("rev-parse", "--verify", kept.reference), "The ref Git made is the snapshot's")
        try AgentCheckpointStore().remove(kept)

        let neverMade = AgentCheckpointStore(git: try Self.git(#"case "$*" in *"update-ref refs/tab"*) echo "error: timed out" >&2; exit 1 ;; esac"#, in: try folder()))
        XCTAssertThrowsError(try neverMade.capture(directory: repo.path))
        XCTAssertEqual(try refs(), "")

        let unclear = AgentCheckpointStore(git: try Self.git(#"case "$*" in *"update-ref refs/tab"*) /usr/bin/git "$@"; exit 1 ;; *--exists*) exit 1 ;; esac"#, in: try folder()))
        XCTAssertThrowsError(try unclear.capture(directory: repo.path))
        XCTAssertEqual(try refs(), "", "A ref that may be there is removed")
    }

    /// A removal Git made without reporting it, as when its hook outlasted the time allowed,
    /// still counts: a capture whose ref went that way fails rather than returning a
    /// checkpoint nothing pins, and one whose ref Git can't account for is handed back to
    /// be kept track of.
    func testACaptureWhosePinCantBeSettledIsNeverACheckpoint() throws {
        let repo = try GitTestRepo(commit: true)
        func refs() throws -> String { try repo.run("for-each-ref", "refs/tab/checkpoints/").trimmingCharacters(in: .whitespacesAndNewlines) }
        let tools = try folder(), lookups = tools.appendingPathComponent("lookups")
        // A Git before 2.43 whose ref changes go through unreported, and whose first lookup goes unanswered.
        let unreported = AgentCheckpointStore(git: try Self.git("""
            case " $* " in
              *" show-ref --exists "*)
                n=$(($(cat '\(lookups.path)' 2>/dev/null || echo 0) + 1)); echo $n > '\(lookups.path)'
                [ $n -eq 1 ] && { head -c 5000000 /dev/zero; exit 0; }
                echo "error: unknown option" >&2; exit 129 ;;
              *" update-ref "*) /usr/bin/git "$@" || exit; head -c 5000000 /dev/zero; exit 0 ;;
            esac
            """, in: tools))
        XCTAssertThrowsError(try unreported.capture(directory: repo.path)) { XCTAssertFalse($0 is AgentCheckpointStore.UnsettledPin, "\($0)") }
        XCTAssertEqual(try refs(), "", "Its ref went")

        let unknowable = AgentCheckpointStore(git: try Self.git("""
            case " $* " in
              *" show-ref --exists "*) head -c 5000000 /dev/zero; exit 0 ;;
              *" update-ref --no-deref -d "*) exit 1 ;;
              *" update-ref "*) /usr/bin/git "$@" || exit; head -c 5000000 /dev/zero; exit 0 ;;
            esac
            """, in: try folder()))
        var unsettled: AgentCheckpointStore.UnsettledPin?
        XCTAssertThrowsError(try unknowable.capture(directory: repo.path)) { unsettled = $0 as? AgentCheckpointStore.UnsettledPin }
        let pin = try XCTUnwrap(unsettled, "Handed back unsettled")
        XCTAssertNoThrow(try repo.run("rev-parse", "--verify", pin.snapshot.reference), "With the ref Git made")
        try AgentCheckpointStore().remove(pin.snapshot)
        XCTAssertEqual(try refs(), "")
    }

    /// On a Git before 2.43, a ref kept as a link to another checkpoint's still counts as there.
    func testOlderGitCountsALinkedRefAsThere() throws {
        let repo = try GitTestRepo(commit: true)
        let store = AgentCheckpointStore(), older = AgentCheckpointStore(git: try Self.git(Self.withoutExists, in: try folder()))
        let linked = try store.capture(directory: repo.path), other = try store.capture(directory: repo.path)
        try repo.run("-c", "core.preferSymlinkRefs=true", "symbolic-ref", linked.reference, other.reference)
        let lock = URL(fileURLWithPath: repo.path).appendingPathComponent(".git/" + linked.reference + ".lock")
        try Data().write(to: lock)
        defer { try? FileManager.default.removeItem(at: lock) }
        XCTAssertThrowsError(try older.remove(linked), "A link Git couldn't remove yet still pins its tree")
    }

    /// A ref whose name became a folder of other refs is gone; the refs inside stay.
    func testARefWhoseNameBecameAFolderIsGone() throws {
        let repo = try GitTestRepo(commit: true)
        let snapshot = try AgentCheckpointStore().capture(directory: repo.path)
        try repo.run("update-ref", "-d", snapshot.reference)
        try repo.run("update-ref", snapshot.reference + "/child", snapshot.tree)
        XCTAssertNoThrow(try AgentCheckpointStore().remove(snapshot))
        let unreadable = AgentCheckpointStore(git: try Self.git(#"for a in "$@"; do [ "$a" = --exists ] && exit 1; done"#, in: try folder()))
        XCTAssertNoThrow(try unreadable.remove(snapshot), "Even where Git can't read the folder as a ref")
        XCTAssertNoThrow(try AgentCheckpointStore(git: try Self.git(Self.withoutExists, in: try folder())).remove(snapshot),
                         "And on a Git before 2.43")
        XCTAssertNoThrow(try repo.run("rev-parse", "--verify", snapshot.reference + "/child"), "The refs inside stay")
    }

    /// Git before 2.43 can't tell a missing ref from one it couldn't read, and a failed
    /// removal can say anything: only the ref files decide, so a ref still there stays.
    func testOlderGitKeepsARefItCouldNotReadOrRemove() throws {
        let repo = try GitTestRepo(commit: true)
        let snapshot = try AgentCheckpointStore().capture(directory: repo.path)
        let failing = AgentCheckpointStore(git: try Self.git("""
            case "$*" in
            *update-ref*) echo "error: Input/output error" >&2; exit 1 ;;
            *--exists*) echo "error: unknown option" >&2; exit 129 ;;
            *--quiet*) exit 1 ;;
            esac
            """, in: try folder()))
        XCTAssertThrowsError(try failing.remove(snapshot))
        XCTAssertNoThrow(try repo.run("rev-parse", "--verify", snapshot.reference), "The ref stays")
        XCTAssertNoThrow(try AgentCheckpointStore().remove(snapshot), "A later try with a working Git removes it")
        XCTAssertThrowsError(try repo.run("rev-parse", "--verify", "--quiet", snapshot.reference))
    }

    /// A worktree whose repository was deleted links to nothing: its refs went with it.
    func testAWorktreeWhoseRepositoryIsGoneHasNothingLeftToRemove() throws {
        let repo = try GitTestRepo(commit: true)
        let worktree = repo.path + "-orphan"
        try repo.run("worktree", "add", "--detach", worktree)
        defer { try? FileManager.default.removeItem(atPath: worktree) }
        var older = try AgentCheckpointStore().capture(directory: worktree)
        older.repository = nil
        try FileManager.default.removeItem(atPath: repo.path)
        XCTAssertNoThrow(try AgentCheckpointStore().remove(older))
    }

    /// A private ref someone pointed elsewhere stays; one Git can't lock yet is kept for later.
    func testRemovingARefSettlesOnlyWhenNothingIsLeftToDo() throws {
        let repo = try GitTestRepo(commit: true)
        let store = AgentCheckpointStore()
        let replaced = try store.capture(directory: repo.path)
        let other = try repo.run("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        try repo.run("update-ref", replaced.reference, other)
        XCTAssertNoThrow(try store.remove(replaced))
        XCTAssertEqual(try repo.run("rev-parse", replaced.reference).trimmingCharacters(in: .whitespacesAndNewlines), other)

        let locked = try store.capture(directory: repo.path)
        let lock = URL(fileURLWithPath: repo.path).appendingPathComponent(".git/" + locked.reference + ".lock")
        try Data().write(to: lock)
        XCTAssertThrowsError(try store.remove(locked))
        XCTAssertNoThrow(try repo.run("rev-parse", "--verify", locked.reference))
        try FileManager.default.removeItem(at: lock)
        XCTAssertNoThrow(try store.remove(locked))
        XCTAssertThrowsError(try repo.run("rev-parse", "--verify", "--quiet", locked.reference))
        XCTAssertNoThrow(try store.remove(locked), "Already gone is settled")

        let elsewhere = AgentCheckpointStore.Snapshot(tree: locked.tree, reference: locked.reference,
                                                      directory: repo.path + "/missing-folder")
        XCTAssertNoThrow(try store.remove(elsewhere), "A repository that is gone took its refs with it")

        let link = URL(fileURLWithPath: repo.path + "-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: repo.path + "/missing-folder"))
        defer { try? FileManager.default.removeItem(at: link) }
        let dangling = AgentCheckpointStore.Snapshot(tree: locked.tree, reference: locked.reference, directory: link.path)
        XCTAssertNoThrow(try store.remove(dangling), "So is one whose link leads nowhere")
    }

    /// Git reports refs and repositories it may not read as missing; their refs aren't
    /// taken as removed until Git can reach them.
    func testRefsGitMayNotReadAreRemovedOnceItCan() throws {
        try XCTSkipIf(geteuid() == 0, "Root ignores file permissions")
        let repo = try GitTestRepo(commit: true)
        let store = AgentCheckpointStore()
        let git = URL(fileURLWithPath: repo.path).appendingPathComponent(".git")
        for folder in [git.appendingPathComponent("refs/tab/checkpoints"), git.appendingPathComponent("refs/tab"), git] {
            let snapshot = try store.capture(directory: repo.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
            XCTAssertThrowsError(try store.remove(snapshot), folder.lastPathComponent)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            XCTAssertNoThrow(try repo.run("rev-parse", "--verify", snapshot.reference), "\(folder.lastPathComponent): the ref stays")
            XCTAssertNoThrow(try store.remove(snapshot))
            XCTAssertThrowsError(try repo.run("rev-parse", "--verify", "--quiet", snapshot.reference))
        }
    }

    func testSummaryRetainsManyFilesAndDefersDetailedPatchUntilRequested() throws {
        let repo = try GitTestRepo(commit: false)
        let store = AgentCheckpointStore()
        let before = try store.capture(directory: repo.path)
        defer { try? store.remove(before) }
        for index in 0..<80 { try repo.write("file-\(index).txt", "first\nsecond\n") }
        let after = try store.capture(directory: repo.path)
        defer { try? store.remove(after) }
        let files = try store.files(from: before, to: after)
        XCTAssertEqual(files.count, 80)
        XCTAssertTrue(files.allSatisfy { $0.additions == 2 && $0.deletions == 0 })
        let record = AgentCheckpointRecord(before: before, after: after, files: files)
        let summary = record.summary(id: UUID().uuidString)
        XCTAssertEqual(summary.files.count, 64)
        XCTAssertEqual(summary.totalFiles, 80)
        XCTAssertEqual(summary.additions, 160)
        XCTAssertTrue(summary.truncated)
        let diff = try store.diff(from: before, to: after, path: "file-79.txt")
        XCTAssertTrue(diff.rows.contains { $0.text == "+second" })
    }

    func testUnbornRepositoryAndBinaryChanges() throws {
        let repo = try GitTestRepo(commit: false)
        let store = AgentCheckpointStore()
        let before = try store.capture(directory: repo.path)
        defer { try? store.remove(before) }
        try Data([0, 1, 2, 0]).write(to: URL(fileURLWithPath: repo.path + "/binary"))
        let after = try store.capture(directory: repo.path)
        defer { try? store.remove(after) }
        let changes = try store.files(from: before, to: after)
        XCTAssertEqual(changes.map(\.path), ["binary"])
        XCTAssertNil(changes.first?.additions)
        XCTAssertNil(changes.first?.deletions)
        XCTAssertThrowsError(try repo.run("rev-parse", "--verify", "HEAD"))
    }

    /// Later captures start from the last capture's index, so a file an earlier turn
    /// changed isn't hashed again, and the captures stay exact when the user's own
    /// index moves on in between.
    func testCapturesReuseTheirIndexAndStayExact() throws {
        let repo = try GitTestRepo(commit: false)
        try repo.write("kept.txt", "kept\n")
        try repo.write("edited.txt", "one\n")
        try repo.commit("initial")
        let store = AgentCheckpointStore()
        let first = try store.capture(directory: repo.path)
        defer { try? store.remove(first) }
        let gitDirectory = try repo.run("rev-parse", "--absolute-git-dir").trimmingCharacters(in: .whitespacesAndNewlines)
        let cache = URL(fileURLWithPath: gitDirectory).appendingPathComponent("tab-checkpoint-index-" + AgentCheckpointStore.folderKey(repo.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
        try repo.write("edited.txt", "two\n")
        try repo.write("new.txt", "new\n")
        let second = try store.capture(directory: repo.path)
        defer { try? store.remove(second) }
        // The user stages and removes files between turns; the checkpoint follows the folder.
        try repo.run("add", "new.txt")
        try FileManager.default.removeItem(atPath: (repo.path as NSString).appendingPathComponent("kept.txt"))
        let third = try store.capture(directory: repo.path)
        defer { try? store.remove(third) }
        XCTAssertEqual(Set(try store.files(from: first, to: second).map(\.path)), ["edited.txt", "new.txt"])
        XCTAssertEqual(try store.files(from: second, to: third).map(\.path), ["kept.txt"])
        XCTAssertEqual(try repo.run("show", ":kept.txt"), "kept\n", "The user's index is untouched")
    }
}
