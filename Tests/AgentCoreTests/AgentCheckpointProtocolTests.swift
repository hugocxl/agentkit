import Foundation
import XCTest
@testable import AgentCore

/// Checkpoint status, rewinds and diff context only add optional fields and cases, so records
/// from older runtimes still decode and read sensibly, and newer states stay readable.
final class AgentCheckpointProtocolTests: XCTestCase {
    private func turn(_ json: String) throws -> AgentChatTurn {
        try JSONDecoder().decode(AgentChatTurn.self, from: Data(json.utf8))
    }

    func testTurnsFromOlderRuntimesReadFromTheirCheckpointAlone() throws {
        let checkpoint = UUID().uuidString
        let changed = try turn(#"{"userItemID":"u1","startedAt":0,"status":"idle","checkpoint":{"id":"\#(checkpoint)","files":[],"totalFiles":2,"additions":3,"deletions":1,"truncated":false}}"#)
        XCTAssertNil(changed.checkpointStatus)
        XCTAssertNil(changed.rewindable)
        XCTAssertEqual(changed.checkpointPhase, .changed)
        let unchanged = try turn(#"{"userItemID":"u1","startedAt":0,"status":"idle","checkpoint":{"id":"\#(checkpoint)","files":[],"totalFiles":0,"additions":0,"deletions":0,"truncated":false}}"#)
        XCTAssertEqual(unchanged.checkpointPhase, .unchanged)
        XCTAssertEqual(try turn(#"{"userItemID":"u1","startedAt":0,"status":"idle"}"#).checkpointPhase, .unknown)
    }

    func testEveryStateIsDistinctAndUnknownStatesReadAsUnavailable() throws {
        var turn = AgentChatTurn(userItemID: "u1", startedAt: Date(), completedAt: Date(), status: .idle)
        turn.checkpointStatus = .init(state: .capturing)
        XCTAssertEqual(turn.checkpointPhase, .capturing)
        turn.checkpointStatus = .init(state: .untracked, reason: "Not in Git")
        XCTAssertEqual(turn.checkpointPhase, .untracked(reason: "Not in Git"))
        turn.checkpointStatus = .init(state: .unavailable, reason: "Git timed out", retryable: true)
        XCTAssertEqual(turn.checkpointPhase, .unavailable(reason: "Git timed out", retryable: true))
        turn.checkpointStatus = .init(state: .ready)
        XCTAssertEqual(turn.checkpointPhase, .unknown, "Ready without its checkpoint is still arriving")
        turn.checkpoint = AgentTurnCheckpoint(id: UUID().uuidString, files: [], totalFiles: 0, additions: 0, deletions: 0)
        XCTAssertEqual(turn.checkpointPhase, .unchanged)

        let future = try self.turn(#"{"userItemID":"u1","startedAt":0,"status":"idle","checkpointStatus":{"state":"pruned","reason":"Later"}}"#)
        XCTAssertEqual(future.checkpointPhase, .unavailable(reason: "Later", retryable: false))
        let again = try JSONDecoder().decode(AgentChatTurn.self, from: JSONEncoder().encode(future))
        XCTAssertEqual(again.checkpointStatus?.state.rawValue, "pruned", "Unknown states round-trip")
    }

    func testReasonsAreBoundedBetweenCharactersAndValidated() throws {
        let status = AgentTurnCheckpointStatus(state: .unavailable, reason: String(repeating: "é", count: 600))
        let reason = try XCTUnwrap(status.reason)
        XCTAssertLessThanOrEqual(reason.utf8.count, AgentTurnCheckpointStatus.maxReasonBytes)
        XCTAssertTrue(reason.hasSuffix("…"))
        XCTAssertTrue(reason.dropLast().allSatisfy { $0 == "é" })

        var snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude)
        snapshot.items = [AgentChatItem(id: "u1", kind: .user, text: "Edit")]
        var turn = AgentChatTurn(userItemID: "u1", startedAt: Date())
        turn.checkpointStatus = status
        snapshot.turns = [turn]
        XCTAssertNoThrow(try snapshot.validate())
        snapshot.turns?[0].checkpointStatus?.reason = String(repeating: "x", count: AgentTurnCheckpointStatus.maxReasonBytes + 1)
        XCTAssertThrowsError(try snapshot.validate())
    }

    func testRewindRetryAndContextRequestsValidateAndRoundTrip() throws {
        let session = SessionId()
        let rewind = AgentConversationRequest.rewind(session: session, at: "u1", archive: SessionId(), revision: 4, restoreFiles: true, force: false)
        XCTAssertNoThrow(try rewind.validate())
        XCTAssertEqual(rewind.session, session)
        XCTAssertEqual(try JSONDecoder().decode(AgentConversationRequest.self, from: JSONEncoder().encode(rewind)), rewind)
        XCTAssertThrowsError(try AgentConversationRequest.rewind(session: session, at: "u1", archive: session, revision: 4,
                                                                 restoreFiles: false, force: false).validate())
        XCTAssertThrowsError(try AgentConversationRequest.rewind(session: session, at: "", archive: SessionId(), revision: 4,
                                                                 restoreFiles: false, force: false).validate())
        XCTAssertNoThrow(try AgentConversationRequest.retryCheckpoint(session: session, turn: "u1").validate())
        XCTAssertThrowsError(try AgentConversationRequest.retryCheckpoint(session: session, turn: "").validate())

        let checkpoint = UUID().uuidString
        let older = try JSONDecoder().decode(AgentCheckpointRequest.self,
            from: Data(#"{"session":"\#(session)","checkpoint":"\#(checkpoint)","offset":0}"#.utf8))
        XCTAssertNil(older.context)
        XCTAssertNoThrow(try AgentCheckpointRequest(session: session, checkpoint: checkpoint, path: "a", context: AgentCheckpointRequest.wholeFile).validate())
        XCTAssertThrowsError(try AgentCheckpointRequest(session: session, checkpoint: checkpoint, path: "a", context: -1).validate())
        XCTAssertThrowsError(try AgentCheckpointRequest(session: session, checkpoint: checkpoint, path: "a", context: AgentCheckpointRequest.wholeFile + 1).validate())
    }

    func testRevertAndRewindRepliesFromOlderAndNewerRuntimes() throws {
        let older = try JSONDecoder().decode(AgentRevertReply.self, from: Data(#"{"reverted":["a"],"conflicts":[]}"#.utf8))
        XCTAssertNil(older.unchanged)
        let reply = AgentConversationReply.rewound(AgentRewindReply(snapshot: nil, files: AgentRevertReply(conflicts: ["b"])))
        XCTAssertNoThrow(try reply.validate())
        XCTAssertEqual(try JSONDecoder().decode(AgentConversationReply.self, from: JSONEncoder().encode(reply)), reply)
        let tooMany = AgentConversationReply.revert(AgentRevertReply(reverted: Array(repeating: "a", count: 4096),
                                                                     unchanged: Array(repeating: "b", count: 4097)))
        XCTAssertThrowsError(try tooMany.validate())
    }
}
