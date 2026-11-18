import AgentCore
import AppKit
import XCTest
@testable import AgentUI

/// Edit as New Prompt restores a sent message's text and attachments into the draft; Edit
/// from Here shows what goes, lets the user keep or restore files, and changes nothing until
/// the runtime has done it. The changes card says where recording a turn's files stands.
@MainActor
final class AgentRewindPaneTests: XCTestCase {
    private let session = SessionId(), project = ProjectId()
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    /// Three turns: the second with a screenshot only, each with a checkpoint.
    private func snapshot(provider: AgentChatProvider = .claude, rewindable: Bool? = true) -> AgentChatSnapshot {
        var snapshot = AgentChatSnapshot(session: session, project: project, provider: provider, status: .idle, revision: 5)
        let shot = AgentChatAttachmentDescriptor(id: "shot", name: "shot.png", mimeType: "image/png", byteCount: 8)
        snapshot.items = [
            .init(id: "u1", kind: .user, text: "First"), .init(id: "a1", kind: .assistant, text: "One"),
            .init(id: "u2", kind: .user, text: "", attachments: [shot]), .init(id: "a2", kind: .assistant, text: "Two"),
            .init(id: "u3", kind: .user, text: "Third\nmore"), .init(id: "a3", kind: .assistant, text: "Three")
        ]
        snapshot.turns = ["u1", "u2", "u3"].enumerated().map { index, id in
            var turn = AgentChatTurn(userItemID: id, startedAt: Date(timeIntervalSinceNow: -60), completedAt: Date(), status: .idle,
                                     checkpoint: AgentTurnCheckpoint(id: UUID().uuidString, files: [.init(path: "f\(index).swift", additions: 1, deletions: 0)],
                                                                     totalFiles: 1, additions: 1, deletions: 0))
            turn.checkpointStatus = AgentTurnCheckpointStatus(state: .ready)
            turn.rewindable = rewindable
            return turn
        }
        return snapshot
    }

    private func pane(_ snapshot: AgentChatSnapshot) async throws -> AgentPaneController {
        _ = NSApplication.shared
        let pane = AgentPaneController(session: session, project: project, provider: snapshot.provider) { _ in snapshot }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        return pane
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    func testEditAsNewPromptRestoresAnImageOnlyMessageAndNamesMissingAttachments() async throws {
        let source = snapshot()
        let pane = try await pane(source)
        defer { pane.dispose() }
        pane.surface.fetchAttachment = { [png] item, descriptor in
            XCTAssertEqual(item, "u2")
            XCTAssertEqual(descriptor.id, "shot")
            return png
        }
        let shot = try XCTUnwrap(source.items.first { $0.id == "u2" })
        pane.editAsNewPrompt(shot)
        try await wait { pane.draftAttachments.count == 1 }
        XCTAssertEqual(pane.draftAttachments.first?.data, png)
        XCTAssertEqual(pane.draftAttachments.first?.name, "shot.png")
        XCTAssertEqual(pane.surface.composer.string, "")

        // Bytes the backend no longer has are named, and the rest of the message still arrives.
        pane.surface.fetchAttachment = { _, _ in throw ModelError("expired") }
        var both = shot
        both.text = "Look again"
        pane.editAsNewPrompt(both)
        try await wait { pane.notice?.text.contains("shot.png") == true }
        XCTAssertEqual(pane.notice?.text, "An attachment is no longer available and wasn't added: “shot.png”.")
        XCTAssertEqual(pane.surface.composer.string, "Look again")
        XCTAssertEqual(pane.draftAttachments.count, 1, "The earlier attachment stays")
    }

    func testRewindPlansNameTheTurnsTheyRemoveAndWhetherFilesCanBeRestored() throws {
        let source = snapshot()
        let second = try XCTUnwrap(source.items.first { $0.id == "u2" })
        guard case .success(let plan) = AgentRewindPlan.make(source, item: second) else { return XCTFail("Rewindable") }
        XCTAssertEqual(plan.turns.map(\.userItemID), ["u2", "u3"])
        XCTAssertEqual(plan.messages, ["(1 attachment)", "Third"])
        XCTAssertEqual(plan.changedFiles, 2)
        XCTAssertTrue(plan.canRestoreFiles)
        XCTAssertTrue(plan.summary.contains("Keep them as they are, or put them back"))

        XCTAssertEqual(AgentRewindPlan.make(snapshot(provider: .codex), item: second),
                       .failure(.init("Codex can't continue from an earlier message. Use Edit as New Prompt instead.")))
        XCTAssertEqual(AgentRewindPlan.make(snapshot(rewindable: nil), item: second),
                       .failure(.init("This agent service can't rewind a conversation.")))
        XCTAssertEqual(AgentRewindPlan.make(snapshot(rewindable: false), item: second),
                       .failure(.init("Claude Code can't continue from before this message.")))
        var working = source
        working.status = .working
        XCTAssertEqual(AgentRewindPlan.make(working, item: second),
                       .failure(.init("Stop active work and remove queued prompts before editing from here.")))

        var unrecorded = source
        unrecorded.turns?[2].checkpoint = nil
        unrecorded.turns?[2].checkpointStatus = .init(state: .unavailable, reason: "Git timed out", retryable: false)
        guard case .success(let partial) = AgentRewindPlan.make(unrecorded, item: second) else { return XCTFail("Still rewindable") }
        XCTAssertFalse(partial.canRestoreFiles)
        XCTAssertEqual(partial.restoreUnavailable, "Turn 3's changes weren't recorded: Git timed out")
        XCTAssertTrue(partial.summary.contains("Files stay as they are. Turn 3's changes weren't recorded"))
    }

    /// The user chooses, the runtime rewinds and restores, then the message joins the kept
    /// draft; files changed since need a second confirmation.
    func testEditFromHereRewindsThenPutsTheMessageInTheKeptDraft() async throws {
        let source = snapshot()
        let pane = try await pane(source)
        defer { pane.dispose() }
        pane.surface.fetchAttachment = { [png] _, _ in png }
        pane.surface.composer.string = "Keep this"
        var plans: [AgentRewindPlan] = []
        pane.chooseRewind = { plans.append($0); return .restoreFiles }
        var confirmations: [String] = []
        pane.confirmDestructive = { title, _, _ in confirmations.append(title); return true }
        var rewound = source
        rewound.items = Array(source.items.prefix(2)) + [AgentChatItem(kind: .notice, text: "Rewound")]
        rewound.turns = Array(source.turns?.prefix(1) ?? [])
        rewound.revision = 7
        rewound.resetID = SessionId()
        var requests: [AgentConversationRequest] = []
        pane.conversationRequest = { request in
            requests.append(request)
            guard case .rewind(_, _, _, _, _, let force) = request else { throw ModelError("unexpected") }
            return .rewound(force ? AgentRewindReply(snapshot: rewound, files: AgentRevertReply(reverted: ["f1.swift", "f2.swift"]))
                                  : AgentRewindReply(snapshot: nil, files: AgentRevertReply(conflicts: ["f2.swift"])))
        }
        let second = try XCTUnwrap(source.items.first { $0.id == "u2" })
        pane.editFromHere(second)
        try await wait { pane.snapshot?.revision == 7 }
        try await wait { pane.draftAttachments.count == 1 }
        XCTAssertEqual(plans.first?.turns.count, 2)
        XCTAssertEqual(confirmations, ["1 file changed after these turns"])
        guard requests.count == 2, case .rewind(_, "u2", let archive, 5, true, false) = requests[0],
              case .rewind(_, "u2", archive, 5, true, true) = requests[1] else { return XCTFail("\(requests)") }
        XCTAssertEqual(pane.surface.composer.string, "Keep this", "An image-only message adds its image, and the draft is kept")
        XCTAssertEqual(pane.notice?.text, "Rewound and restored 2 files. The message is in the composer.")
    }

    func testCancellingOrFailingEditFromHereChangesNothing() async throws {
        let source = snapshot()
        let pane = try await pane(source)
        defer { pane.dispose() }
        pane.surface.composer.string = "Draft"
        var asked = 0
        pane.conversationRequest = { _ in asked += 1; throw ModelError("The conversation changed. Review it before editing from here.") }
        pane.chooseRewind = { _ in nil }
        let third = try XCTUnwrap(source.items.first { $0.id == "u3" })
        pane.editFromHere(third)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(asked, 0, "Cancelling asks nothing")

        pane.chooseRewind = { _ in .keepFiles }
        pane.editFromHere(third)
        try await wait { pane.notice?.text.hasPrefix("Couldn't edit from here") == true }
        XCTAssertEqual(pane.surface.composer.string, "Draft")
        XCTAssertEqual(pane.snapshot?.revision, 5)

        pane.conversationRequest = { _ in throw ErrorReply(code: .unsupported, message: "") }
        pane.editFromHere(third)
        try await wait { pane.notice?.text.hasSuffix("Nothing was changed.") == true }
        XCTAssertEqual(pane.surface.composer.string, "Draft")

        // Unsupported providers say why before asking anything.
        let codex = try await self.pane(snapshot(provider: .codex))
        defer { codex.dispose() }
        codex.conversationRequest = { _ in throw ModelError("Nothing is asked") }
        codex.editFromHere(try XCTUnwrap(source.items.first { $0.id == "u2" }))
        XCTAssertEqual(codex.notice?.text, "Edit from Here is unavailable. Codex can't continue from an earlier message. Use Edit as New Prompt instead.")
    }

    /// Revert says why it can't run while this conversation's agent works, and a second
    /// client's revert says the files were already put back.
    func testRevertExplainsWhyItIsUnavailableAndWhatAnotherClientDid() async throws {
        var source = snapshot()
        source.status = .working
        let pane = try await pane(source)
        defer { pane.dispose() }
        var asked = 0
        pane.conversationRequest = { _ in asked += 1; return .revert(AgentRevertReply(unchanged: ["f0.swift"])) }
        let checkpoint = try XCTUnwrap(source.turns?.first?.checkpoint)
        pane.revertTurn(checkpoint, paths: nil)
        XCTAssertEqual(pane.notice?.text, "Revert is unavailable. Stop the agent first: it may be changing these files.")
        XCTAssertEqual(asked, 0)

        XCTAssertEqual(AgentRevertAvailability.outcome(AgentRevertReply(unchanged: ["a"])), "Already reverted: the file is as it was before this turn.")
        XCTAssertEqual(AgentRevertAvailability.outcome(AgentRevertReply(reverted: ["a"], unchanged: ["b", "c"])),
                       "Reverted 1 file. 2 files were already as before.")
        var children = snapshot()
        children.subagents = [AgentSubagent(id: "a", toolUseID: "t", description: "Child", background: true)]
        XCTAssertEqual(AgentRevertAvailability.reason(children, submitting: false),
                       "This conversation's agents are still running and may change these files. Wait for them or stop them first.")
    }

    /// The card shows recording, why changes are unavailable with Retry when the runtime can
    /// try again, and a folder outside Git, instead of an empty file list.
    func testChangedFilesCardShowsEachRecordingStateAndRetries() throws {
        let row = AgentChangedFilesRow(frame: NSRect(x: 0, y: 0, width: 600, height: 120))
        var retried: [String] = []
        row.onRetryCheckpoint = { retried.append($0) }
        row.onRevert = { _, _ in }
        row.turnID = "u1"
        func visible(_ title: String) -> PillButton? {
            row.layoutRow(width: 600)
            return row.subviews.compactMap { $0 as? PillButton }.first { $0.title == title && !$0.isHidden }
        }
        func texts() -> [String] { row.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }.map(\.stringValue) }

        row.phase = .capturing
        XCTAssertTrue(texts().contains("Recording file changes…"))
        XCTAssertNil(visible("Retry"))
        XCTAssertNil(visible("Revert"))
        row.phase = .unavailable(reason: "Git timed out", retryable: true)
        XCTAssertTrue(texts().contains("File changes unavailable"))
        XCTAssertTrue(texts().contains("Git timed out"))
        try XCTUnwrap(visible("Retry")).perform()
        XCTAssertEqual(retried, ["u1"])
        row.phase = .unavailable(reason: "Baseline gone", retryable: false)
        XCTAssertNil(visible("Retry"))
        row.phase = .untracked(reason: "Not in Git")
        XCTAssertTrue(texts().contains("File changes aren't recorded"))
        XCTAssertNil(visible("Retry"))
        row.phase = .changed
        row.checkpoint = AgentTurnCheckpoint(id: UUID().uuidString, files: [.init(path: "a.swift", additions: 1, deletions: 0)],
                                             totalFiles: 1, additions: 1, deletions: 0)
        XCTAssertTrue(texts().contains("1 changed file"))
        XCTAssertNotNil(visible("Revert"))

        XCTAssertFalse(AgentChatTurn.CheckpointPhase.unchanged.showsCard)
        var running = AgentChatTurn(userItemID: "u1", startedAt: Date())
        running.checkpointStatus = .init(state: .capturing)
        XCTAssertEqual(running.reviewPhase, .unknown, "Nothing shows while the turn still works")
    }

    /// Retry asks the runtime to record the turn again and shows what it answers.
    func testRetryCheckpointAsksTheRuntimeAndShowsItsAnswer() async throws {
        var source = snapshot()
        source.turns?[2].checkpoint = nil
        source.turns?[2].checkpointStatus = .init(state: .unavailable, reason: "Git timed out", retryable: true)
        let pane = try await pane(source)
        defer { pane.dispose() }
        var capturing = source
        capturing.turns?[2].checkpointStatus = .init(state: .capturing)
        capturing.revision = 6
        var requests: [AgentConversationRequest] = []
        pane.conversationRequest = { requests.append($0); return .snapshot(capturing) }
        pane.retryCheckpoint("u3")
        try await wait { pane.snapshot?.revision == 6 }
        XCTAssertEqual(requests, [.retryCheckpoint(session: session, turn: "u3")])
        XCTAssertEqual(pane.snapshot?.turns?.last?.checkpointPhase, .capturing)
    }
}
