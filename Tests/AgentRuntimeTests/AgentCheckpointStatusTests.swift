import AgentCore
import Foundation
import XCTest
@testable import AgentRuntime

/// A turn says where recording its file changes stands, so a client tells a folder outside
/// Git, a capture that failed, one still under way and a turn that changed nothing apart, and
/// offers Retry only while the turn's original baseline can still be used.
final class AgentCheckpointStatusTests: AgentRestoreTestCase {
    /// Fails or holds the capture that records a turn's result, armed as the turn works.
    private final class CaptureControl: @unchecked Sendable {
        private let lock = NSLock()
        private var armedFailure = false
        private var armedGate: DispatchSemaphore?
        private var failing = false
        private var gate: DispatchSemaphore?
        /// Turns from now on fail to record their result.
        var failsResult: Bool {
            get { lock.withLock { armedFailure } }
            set { lock.withLock { armedFailure = newValue } }
        }
        /// The next turn's result waits for the returned gate.
        func hold() -> DispatchSemaphore { lock.withLock { let gate = DispatchSemaphore(value: 0); armedGate = gate; return gate } }
        /// Called as a turn works, after its baseline: the capture after it is the result's.
        func turnWorked() {
            lock.withLock {
                failing = armedFailure
                gate = armedGate
                armedGate = nil
            }
        }
        func willCapture() throws {
            let (failing, gate) = lock.withLock { () -> (Bool, DispatchSemaphore?) in
                defer { self.failing = false; self.gate = nil }
                return (self.failing, self.gate)
            }
            if failing { throw AgentRuntimeError("Git timed out") }
            gate?.wait()
        }
    }

    private func store(_ control: CaptureControl) -> AgentCheckpointStore {
        var store = AgentCheckpointStore()
        store.willCapture = { _ in try control.willCapture() }
        return store
    }

    func testAFolderOutsideGitSaysItsChangesArentRecorded() async throws {
        let root = try storeRoot(), runtimes = RestoreTestRuntimes()
        let folder = root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let directory = folder.path
        let sessions = try sessions(root: root, runtimes: runtimes, directory: { _ in directory }) { folder, _, _ in
            try "x\n".write(toFile: folder + "/file.txt", atomically: true, encoding: .utf8)
        }
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        let done = try await turn(sessions, id, "Work")
        let turn = try XCTUnwrap(done.turns?.last)
        XCTAssertNil(turn.checkpoint)
        guard case .untracked(let reason) = turn.checkpointPhase else { return XCTFail("\(turn.checkpointPhase)") }
        XCTAssertEqual(reason, AgentCheckpointUnavailable.notRepository.errorDescription)
    }

    func testAnUnchangedTurnIsReadyWithNoFiles() async throws {
        let root = try storeRoot(), repo = try GitTestRepo(commit: true), runtimes = RestoreTestRuntimes()
        let directory = repo.path
        let sessions = try sessions(root: root, runtimes: runtimes, directory: { _ in directory }) { _, _, _ in }
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        let done = try await turn(sessions, id, "Look only")
        XCTAssertEqual(done.turns?.last?.checkpointStatus?.state, .ready)
        XCTAssertEqual(done.turns?.last?.checkpoint?.totalFiles, 0)
        XCTAssertEqual(done.turns?.last?.checkpointPhase, .unchanged)
    }

    /// A capture still under way shows as recording once the turn ended, then as ready.
    func testADelayedCaptureShowsAsRecordingUntilItEnds() async throws {
        let root = try storeRoot(), repo = try GitTestRepo(commit: true), runtimes = RestoreTestRuntimes(), control = CaptureControl()
        let directory = repo.path
        let gate = control.hold()
        defer { gate.signal() }
        let sessions = try sessions(root: root, runtimes: runtimes, checkpoints: store(control), directory: { _ in directory }) { folder, _, _ in
            try "x\n".write(toFile: folder + "/file.txt", atomically: true, encoding: .utf8)
            control.turnWorked()
        }
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: id, text: "Work", model: nil))
        let ended = try await waitFor(sessions, id) { $0.status == .idle && $0.turns?.last?.completedAt != nil }
        XCTAssertEqual(ended.turns?.last?.checkpointPhase, .capturing)
        gate.signal()
        let ready = try await waitFor(sessions, id) { $0.turns?.last?.checkpointStatus?.state == .ready }
        XCTAssertEqual(ready.turns?.last?.checkpointPhase, .changed)
        XCTAssertEqual(ready.turns?.last?.checkpoint?.files.map(\.path), ["file.txt"])
    }

    /// A failed capture says why, bounded, and the latest turn may try again from its
    /// original baseline; a turn begun since takes that away.
    func testAFailedCaptureIsRetriedFromItsOriginalBaseline() async throws {
        let root = try storeRoot(), repo = try GitTestRepo(commit: true), runtimes = RestoreTestRuntimes(), control = CaptureControl()
        control.failsResult = true
        let directory = repo.path
        let sessions = try sessions(root: root, runtimes: runtimes, checkpoints: store(control), directory: { _ in directory }) { folder, text, _ in
            try (text + "\n").write(toFile: folder + "/" + text + ".txt", atomically: true, encoding: .utf8)
            control.turnWorked()
        }
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        let failed = try await turn(sessions, id, "first")
        let turnID = try XCTUnwrap(failed.turns?.last?.userItemID)
        XCTAssertEqual(failed.turns?.last?.checkpointPhase, .unavailable(reason: "Git timed out", retryable: true))

        control.failsResult = false
        guard case .snapshot(let retrying) = try await sessions.conversation(.retryCheckpoint(session: id, turn: turnID)) else {
            return XCTFail("Unexpected reply")
        }
        XCTAssertEqual(retrying.turns?.last?.checkpointPhase, .capturing)
        let ready = try await waitFor(sessions, id) { $0.turns?.last?.checkpointStatus?.state == .ready }
        XCTAssertEqual(ready.turns?.last?.checkpoint?.files.map(\.path), ["first.txt"], "Measured from where the turn began")

        // A failure on an older turn can no longer be retried once a later turn began.
        control.failsResult = true
        let second = try await turn(sessions, id, "second")
        let secondID = try XCTUnwrap(second.turns?.last?.userItemID)
        control.failsResult = false
        _ = try await turn(sessions, id, "third")
        let later = try await sessions.handle(.read(session: id))
        XCTAssertEqual(later.turns?[1].checkpointPhase, .unavailable(reason: "Git timed out", retryable: false))
        do {
            _ = try await sessions.conversation(.retryCheckpoint(session: id, turn: secondID))
            XCTFail("Only the latest turn can be recorded again")
        } catch {
            XCTAssertEqual(message(error), "Recording can be tried again only for the latest finished turn.")
        }
    }

    /// A retry whose baseline is gone says so and stops offering Retry.
    func testARetryWithoutItsBaselineSaysSo() async throws {
        let root = try storeRoot(), repo = try GitTestRepo(commit: true), runtimes = RestoreTestRuntimes(), control = CaptureControl()
        control.failsResult = true
        let directory = repo.path
        let sessions = try sessions(root: root, runtimes: runtimes, checkpoints: store(control), directory: { _ in directory }) { _, _, _ in
            control.turnWorked()
        }
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        let failed = try await turn(sessions, id, "Work")
        let turnID = try XCTUnwrap(failed.turns?.last?.userItemID)
        try FileManager.default.removeItem(at: root.appendingPathComponent("checkpoints/\(id)/pending-\(turnID).json"))
        do {
            _ = try await sessions.conversation(.retryCheckpoint(session: id, turn: turnID))
            XCTFail("Nothing to record from")
        } catch {
            XCTAssertEqual(message(error), "The turn's original baseline is gone, so its file changes can't be recorded.")
        }
        let after = try await sessions.handle(.read(session: id))
        XCTAssertEqual(after.turns?.last?.checkpointStatus?.retryable, false)
    }

    /// A capture pending when the service stopped is recorded at the next start from the
    /// saved baseline: a turn whose final capture failed, and a turn the stop interrupted.
    func testRestartResumesAPersistedPendingCapture() async throws {
        for interrupted in [false, true] {
            let root = try storeRoot(), repo = try GitTestRepo(commit: true), runtimes = RestoreTestRuntimes(), control = CaptureControl()
            control.failsResult = !interrupted
            let directory = repo.path
            let id = SessionId()
            do {
                let sessions = try sessions(root: root, runtimes: runtimes, checkpoints: store(control), directory: { _ in directory }) { folder, _, _ in
                    try "x\n".write(toFile: folder + "/file.txt", atomically: true, encoding: .utf8)
                    control.turnWorked()
                }
                _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
                if interrupted {
                    _ = try await sessions.handle(.send(session: id, text: "Warm up", model: nil))
                    _ = try await waitFor(sessions, id) { $0.status == .idle && $0.turns?.last?.checkpointStatus?.state == .ready }
                    runtimes.all.last?.holdsTurns = true
                    _ = try await sessions.handle(.send(session: id, text: "Work", model: nil))
                    let working = try await waitFor(sessions, id) { $0.status == .working && $0.turns?.count == 2 }
                    let pending = root.appendingPathComponent("checkpoints/\(id)/pending-\(try XCTUnwrap(working.turns?.last?.userItemID)).json")
                    try await waitUntil { FileManager.default.fileExists(atPath: pending.path) }
                } else {
                    let failed = try await turn(sessions, id, "Work")
                    XCTAssertEqual(failed.turns?.last?.checkpointStatus?.state, .unavailable)
                }
                sessions.shutdown()
            }
            let restarted = try sessions(root: root, runtimes: runtimes, directory: { _ in directory }) { _, _, _ in }
            defer { restarted.shutdown() }
            let resumed = try await waitFor(restarted, id) { $0.turns?.last?.checkpointStatus?.state == .ready }
            XCTAssertEqual(resumed.turns?.last?.checkpoint?.files.map(\.path), interrupted ? [] : ["file.txt"], "\(interrupted)")
        }
    }

    /// Context around a change, however much is asked for, comes from the checkpoint's own
    /// old and new files: later edits to the working copy never show, a deleted file shows
    /// its old lines, and a binary file stays binary.
    func testMoreContextIsReadFromTheCheckpointNotTheWorkingFile() async throws {
        let root = try storeRoot(), repo = try GitTestRepo(commit: false), runtimes = RestoreTestRuntimes()
        try repo.write("long.txt", (1...40).map { "line \($0)\n" }.joined())
        try repo.write("gone.txt", "a\nb\nc\n")
        try FileManager.default.createDirectory(atPath: repo.path + "/assets", withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: URL(fileURLWithPath: repo.path + "/assets/logo.bin"))
        try repo.commit("initial")
        let directory = repo.path
        let sessions = try sessions(root: root, runtimes: runtimes, directory: { _ in directory }) { folder, _, _ in
            try (1...40).map { $0 == 20 ? "changed 20\n" : "line \($0)\n" }.joined().write(toFile: folder + "/long.txt", atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(atPath: folder + "/gone.txt")
            try Data([9, 9, 0, 9]).write(to: URL(fileURLWithPath: folder + "/assets/logo.bin"))
        }
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        let checkpoint = try await checkpoint(sessions, id, "Edit")
        // The working copy changes after the turn.
        try repo.write("long.txt", (1...40).map { "edited later \($0)\n" }.joined())

        let usual = try await sessions.checkpoint(AgentCheckpointRequest(session: id, checkpoint: checkpoint, path: "long.txt"))
        XCTAssertEqual(usual.context, 3)
        XCTAssertEqual(usual.diff?.rows.compactMap(\.newLineNumber).min(), 17)
        let whole = try await sessions.checkpoint(AgentCheckpointRequest(session: id, checkpoint: checkpoint, path: "long.txt",
                                                                         context: AgentCheckpointRequest.wholeFile))
        XCTAssertEqual(whole.context, AgentCheckpointRequest.wholeFile)
        let lines = try XCTUnwrap(whole.diff?.rows.filter { $0.kind == .context })
        XCTAssertEqual(lines.count, 39)
        XCTAssertTrue(lines.allSatisfy { $0.text.contains("line ") }, "Never the later edits")
        XCTAssertEqual(whole.diff?.rows.first { $0.kind == .addition }?.text, "+changed 20")

        let gone = try await sessions.checkpoint(AgentCheckpointRequest(session: id, checkpoint: checkpoint, path: "gone.txt", context: 25))
        XCTAssertEqual(gone.diff?.rows.filter { $0.kind == .deletion }.compactMap(\.oldLineNumber), [1, 2, 3])
        let binary = try await sessions.checkpoint(AgentCheckpointRequest(session: id, checkpoint: checkpoint, path: "assets/logo.bin", context: 25))
        XCTAssertEqual(binary.diff?.binary, true)
        XCTAssertEqual(binary.diff?.rows, [])
    }
}
