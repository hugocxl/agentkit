import AgentCore
import AppKit
import XCTest
@testable import AgentRuntime
@testable import AgentUI

/// Queue editing (C3, C4) and Send Now (C5) against a real conversation server.
@MainActor
final class AgentQueuedPromptTests: XCTestCase {
    private func harness() throws -> ComposerHarness {
        let harness = try ComposerHarness()
        addTeardownBlock { @MainActor in harness.tearDown() }
        return harness
    }

    private func edit(_ prompt: AgentQueuedPrompt, text: String) -> AgentQueuedPromptEdit {
        var edit = AgentQueuedPromptEdit(prompt: prompt)
        edit.text = text
        return edit
    }

    // MARK: C3

    func testStaleEditFromAnotherClientIsRecoverableAndKeepsTheLatestVersion() async throws {
        let h = try harness()
        let a = h.pane(), b = h.pane()
        try await h.startWorking(a)
        b.refresh()
        let queued = try await h.queue("Queued v1", from: a)
        try await h.until { b.snapshot?.queuedPrompts?.first?.id == queued.id }
        // The other client saves first.
        b.composerWork.presentQueueEdit = { edit, _ in var next = edit; next.text = "B's version"; return next }
        b.editQueued(try XCTUnwrap(b.snapshot?.queuedPrompts?.first))
        _ = try await h.settle { $0.queuedPrompts?.first?.text == "B's version" }

        a.surface.composer.string = "My unrelated draft"
        var problems: [AgentQueueEditProblem] = []
        a.composerWork.resolveQueueEdit = { problems.append($0); return .copy }
        a.saveQueueEdit(edit(queued, text: "A's edit"))
        try await h.until { !problems.isEmpty && a.composerWork.queueEditTask == nil }
        let problem = try XCTUnwrap(problems.first)
        XCTAssertEqual(problem.title, "This queued prompt changed elsewhere")
        XCTAssertEqual(problem.choices, [.review, .copy, .stash, .discard])
        XCTAssertEqual(problem.edit.text, "A's edit", "The user's edit is offered back whole")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "A's edit")
        let server = try await h.read()
        XCTAssertEqual(server.queuedPrompts?.map(\.text), ["B's version"], "The latest queued version is preserved")
        XCTAssertEqual(a.surface.composer.string, "My unrelated draft", "The composer's draft is never touched")
        XCTAssertEqual(h.runtime?.sends, ["Start"], "Nothing was sent by the failed edit")
    }

    func testDroppedSaveReplyIsRecognizedAsSavedAndNeverResent() async throws {
        let h = try harness()
        let a = h.pane()
        try await h.startWorking(a)
        let queued = try await h.queue("Draft step", from: a)
        h.dropNextReply = { if case .updateQueued = $0 { return true }; return false }
        a.composerWork.resolveQueueEdit = { _ in XCTFail("An applied edit needs no decision"); return .discard }
        a.saveQueueEdit(edit(queued, text: "Applied, reply lost"))
        try await h.until { a.notice?.text == "Saved the queued prompt." }
        XCTAssertNil(a.composerWork.queueEdit)
        let server = try await h.read()
        XCTAssertEqual(server.queuedPrompts?.map(\.text), ["Applied, reply lost"])
        XCTAssertEqual(server.queuedPrompts?.first?.revision, 1)
        XCTAssertEqual(h.runtime?.sends, ["Start"])
    }

    func testLostRequestRetriesTheSameRevisionOnceAndRemovedPromptOffersCopyOrStash() async throws {
        let h = try harness()
        let a = h.pane(), b = h.pane()
        try await h.startWorking(a)
        b.refresh()
        let queued = try await h.queue("Original", from: a)
        h.failNext = { if case .updateQueued = $0 { return true }; return false }
        var problems: [AgentQueueEditProblem] = []
        a.composerWork.resolveQueueEdit = { problems.append($0); return .retry }
        a.saveQueueEdit(edit(queued, text: "Retried"))
        _ = try await h.settle { $0.queuedPrompts?.first?.text == "Retried" }
        try await h.until { a.composerWork.queueEdit == nil && a.composerWork.queueEditTask == nil }
        XCTAssertEqual(problems.map(\.choices), [[.retry, .copy, .stash, .keep]])
        let retried = try await h.read()
        XCTAssertEqual(retried.queuedPrompts?.count, 1)

        // The prompt leaves the queue while this client still edits it.
        try await h.until { b.snapshot?.queuedPrompts?.first?.text == "Retried" }
        let latest = try XCTUnwrap(b.snapshot?.queuedPrompts?.first)
        b.run(.removeQueued(session: h.session, id: latest.id, expectedRevision: latest.revision))
        _ = try await h.settle { $0.queuedPrompts?.isEmpty == true }
        problems = []
        a.composerWork.resolveQueueEdit = { problems.append($0); return .keep }
        a.saveQueueEdit(edit(latest, text: "Too late"))
        try await h.until { !problems.isEmpty && a.composerWork.queueEditTask == nil }
        XCTAssertEqual(problems.first?.title, "This prompt is no longer queued")
        XCTAssertEqual(problems.first?.choices, [.copy, .stash, .discard])
        XCTAssertEqual(h.runtime?.sends, ["Start"])
    }

    // MARK: C4

    func testReplacingAScreenshotSurvivesAFailedSaveAndRetry() async throws {
        let h = try harness()
        let a = h.pane()
        try await h.startWorking(a)
        let before = AgentDraftAttachment(name: "Before.png", mimeType: "image/png", data: Data(repeating: 1, count: 40))
        let queued = try await h.queue("Compare", from: a, attachments: [before])
        let after = AgentChatAttachment(name: "After.png", mimeType: "image/png", data: Data(repeating: 2, count: 50))
        var change = AgentQueuedPromptEdit(prompt: queued)
        try change.replace(before.id, with: after)
        XCTAssertTrue(change.attachmentsChanged)
        XCTAssertNil(change.legacyRequest(session: h.session), "An older server can't change attachments")

        h.failNext = { if case .updateQueued = $0 { return true }; return false }
        var checkedBetween = false
        a.composerWork.resolveQueueEdit = { [h] _ in
            // The original server entry stays usable until the replacement succeeds.
            let held = try? await h.sessions.attachment(.init(session: h.session, item: queued.id, attachment: before.id))
            checkedBetween = held?.attachment.data == before.data
            return .retry
        }
        a.saveQueueEdit(change)
        let saved = try await h.settle { $0.queuedPrompts?.first?.attachments.map(\.name) == ["After.png"] }
        XCTAssertTrue(checkedBetween)
        XCTAssertEqual(saved.queuedPrompts?.first?.revision, 1)
        let fetched = try await h.sessions.attachment(.init(session: h.session, item: queued.id, attachment: after.id))
        XCTAssertEqual(fetched.attachment.data, after.data)
    }

    func testAttachmentOnlyPromptBecomingEmptyAsksBeforeRemovingIt() async throws {
        let h = try harness()
        let a = h.pane()
        try await h.startWorking(a)
        let shot = AgentDraftAttachment(name: "Only.png", mimeType: "image/png", data: Data(repeating: 3, count: 30))
        let queued = try await h.queue("", from: a, attachments: [shot])
        var change = AgentQueuedPromptEdit(prompt: queued)
        change.remove(shot.id)
        XCTAssertTrue(change.isEmpty)
        var answers = [false, true]
        a.confirmDestructive = { _, _, _ in answers.removeFirst() }
        a.saveQueueEdit(change)
        try await h.until { a.notice?.kind == .warning && a.composerWork.queueEditTask == nil }
        XCTAssertEqual(a.composerWork.queueEdit, change, "Declining keeps the edit")
        let kept = try await h.read()
        XCTAssertEqual(kept.queuedPrompts?.count, 1)
        a.saveQueueEdit(change)
        _ = try await h.settle { $0.queuedPrompts?.isEmpty == true }
        XCTAssertNil(a.composerWork.queueEdit)
        XCTAssertEqual(h.runtime?.sends, ["Start"], "Removing it sends nothing")
    }

    func testOlderServerTakesTextEditsAndRefusesAttachmentEditsWithoutLosingThem() async throws {
        let h = try harness()
        let a = h.pane()
        try await h.startWorking(a)
        let shot = AgentDraftAttachment(name: "Shot.png", mimeType: "image/png", data: Data(repeating: 5, count: 20))
        let queued = try await h.queue("Old server", from: a, attachments: [shot])
        h.unsupported = { if case .updateQueued = $0 { return true }; return false }
        a.saveQueueEdit(edit(queued, text: "Text only"))
        _ = try await h.settle { $0.queuedPrompts?.first?.text == "Text only" }
        try await h.until { a.composerWork.queueEditTask == nil && a.composerWork.queueEdit == nil }

        let latest = try XCTUnwrap(a.snapshot?.queuedPrompts?.first)
        var change = AgentQueuedPromptEdit(prompt: latest)
        change.remove(shot.id)
        change.text = "Without the shot"
        var problems: [AgentQueueEditProblem] = []
        a.composerWork.resolveQueueEdit = { problems.append($0); return .keep }
        a.saveQueueEdit(change)
        try await h.until { !problems.isEmpty && a.composerWork.queueEditTask == nil }
        XCTAssertTrue(problems[0].message.contains("can't change a queued prompt's attachments"), problems[0].message)
        XCTAssertEqual(a.composerWork.queueEdit, change, "The edit is kept for later")
        let server = try await h.read()
        XCTAssertEqual(server.queuedPrompts?.first?.attachments.map(\.id), [shot.id])
    }

    func testQueuedEditorAddsRemovesAndReplacesWithinLimits() throws {
        let existing = AgentChatAttachmentDescriptor(id: "e", name: "Shot.png", mimeType: "image/png", byteCount: 7 * 1024 * 1024)
        var prompt = AgentQueuedPrompt(prompt: AgentPrompt(text: "Look", model: nil, effort: nil, provider: .codex, planMode: false))
        prompt.attachments = [existing]
        let editor = AgentQueuedPromptEditor(edit: AgentQueuedPromptEdit(prompt: prompt), detail: "", theme: .shared, attachments: true, fetch: nil)
        XCTAssertTrue(editor.strip.hasAttachments)
        let big = AgentChatAttachment(name: "Big.bin", mimeType: "application/octet-stream", data: Data(count: 2 * 1024 * 1024))
        XCTAssertThrowsError(try editor.apply([big], replacing: nil), "The total stays within the attachment limit")
        let small = AgentChatAttachment(name: "New.png", mimeType: "image/png", data: Data([1]))
        try editor.apply([small], replacing: "e")
        XCTAssertEqual(editor.edit.attachments.map(\.id), [small.id])
        try editor.apply([big], replacing: nil)
        XCTAssertEqual(editor.edit.attachments.map(\.descriptor.name), ["New.png", "Big.bin"])
        editor.strip.onRemove?(small.id)
        XCTAssertEqual(editor.edit.attachments.map(\.descriptor.name), ["Big.bin"])
        if case .updateQueued(_, _, let change, _) = editor.edit.request(session: SessionId()) {
            XCTAssertEqual(change.attachments, [.add(big)])
        } else { XCTFail("Attachment edits use the atomic request") }
    }

    // MARK: C5

    func testSendNowJoinsTheRunningResponseOnce() async throws {
        let h = try harness()
        let a = h.pane()
        try await h.startWorking(a)
        a.surface.composer.string = "Also check the tests"
        XCTAssertTrue(a.canSendNow)
        // One action shows at a time: the draft offers Send, and Send Now comes from its key.
        a.surface.updatePrimaryAction()
        XCTAssertFalse(a.surface.send.isHidden)
        XCTAssertTrue(a.surface.stop.isHidden)
        a.sendNow()
        try await h.until { !a.composerWork.sendNowOutcomes.isEmpty }
        XCTAssertEqual(a.composerWork.sendNowOutcomes, [.steered])
        XCTAssertEqual(a.notice?.text, AgentSendNowOutcome.steered.message)
        XCTAssertEqual(h.runtime?.steers, ["Also check the tests"])
        XCTAssertEqual(h.runtime?.sends, ["Start"])
        let after = try await h.read()
        XCTAssertEqual(after.queuedPrompts, [])
    }

    func testSendNowWhileWaitingForApprovalQueuesAndDeliversOnce() async throws {
        let h = try harness()
        let a = h.pane()
        try await h.startWorking(a)
        h.runtime?.callback(.item(AgentChatItem(id: "ask", kind: .approval, text: "Allow?", isComplete: false)))
        h.runtime?.callback(.status(.waiting))
        try await h.until { a.snapshot?.status == .waiting }
        a.surface.composer.string = "After the approval"
        XCTAssertTrue(a.canSendNow)
        a.sendNow()
        try await h.until { !a.composerWork.sendNowOutcomes.isEmpty }
        guard case .queued(let reason) = a.composerWork.sendNowOutcomes.first else { return XCTFail("It waits in the queue") }
        XCTAssertTrue(reason.contains("waiting"), reason)
        XCTAssertEqual(h.runtime?.steers, [])
        h.runtime?.callback(.item(AgentChatItem(id: "ask", kind: .approval, text: "Allowed")))
        h.runtime?.callback(.status(.idle))
        _ = try await h.settle { $0.queuedPrompts?.isEmpty == true && $0.status == .working }
        XCTAssertEqual(h.runtime?.deliveries(of: "After the approval"), 1)
    }

    func testSendNowWhenTheTurnEndsBeforeDispatchStartsOneTurn() async throws {
        let h = try harness()
        let a = h.pane()
        try await h.startWorking(a)
        h.afterSubmit = { [h] in
            // The response ends after the server queued the prompt and before the pane asks to hand it over.
            h.runtime?.callback(.status(.idle))
            _ = try? await h.settle { $0.queuedPrompts?.isEmpty == true }
        }
        a.surface.composer.string = "Raced"
        a.sendNow()
        try await h.until { !a.composerWork.sendNowOutcomes.isEmpty }
        XCTAssertEqual(a.composerWork.sendNowOutcomes, [.startedTurn])
        XCTAssertEqual(h.runtime?.deliveries(of: "Raced"), 1)
        XCTAssertEqual(h.runtime?.steers, [])
    }

    func testSendNowIsUnavailableWhileReconnectingOrWithoutSteering() async throws {
        let h = try harness()
        let a = h.pane()
        try await h.startWorking(a)
        a.surface.composer.string = "Not now"
        a.connectionChanged()
        XCTAssertFalse(a.canSendNow)
        a.sendNow()
        try await h.until { a.snapshot != nil && !a.needsAuthoritativeSnapshot }
        let server = try await h.read()
        XCTAssertEqual(server.queuedPrompts, [])
        XCTAssertEqual(h.runtime?.deliveries(of: "Not now"), 0)
        a.capabilities.remove(.steering)
        a.updateControls()
        XCTAssertFalse(a.canSendNow)
        XCTAssertFalse(a.performConversationShortcut(.sendAgentPromptNow))
    }
}
