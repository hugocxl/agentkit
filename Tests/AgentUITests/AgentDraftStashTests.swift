import AgentCore
import AppKit
import XCTest
@testable import AgentRuntime
@testable import AgentUI

/// The per-conversation stash of unfinished alternatives (C6).
@MainActor
final class AgentDraftStashTests: XCTestCase {
    private func harness() throws -> ComposerHarness {
        let harness = try ComposerHarness()
        addTeardownBlock { @MainActor in harness.tearDown() }
        return harness
    }

    private func connected(_ h: ComposerHarness, draft: URL) async throws -> AgentPaneController {
        let pane = h.pane(draft: draft)
        pane.refresh()
        try await h.until { pane.snapshot != nil && !pane.restoringDraft }
        return pane
    }

    private let citation = "agentkit-citation://quoted"

    /// Text with a quotation, an image and a text file, a review comment and a chosen model.
    private func writeMixedDraft(into pane: AgentPaneController) -> [AgentDraftAttachment] {
        let text = NSMutableAttributedString(string: "Explain this quote please")
        text.addAttribute(.agentAssistantCitation, value: citation, range: NSRange(location: 8, length: 10))
        pane.surface.composer.textStorage?.setAttributedString(text)
        let attachments = [AgentDraftAttachment(name: "Shot.png", mimeType: "image/png", data: Data(repeating: 7, count: 300)),
                           AgentDraftAttachment(name: "Notes.txt", mimeType: "text/plain", data: Data("notes".utf8))]
        pane.draftAttachments = attachments
        pane.reviewComments = [AgentReviewComment(checkpoint: "turn-1", path: "Sources/App.swift", old: false, firstLine: 3, lastLine: 4,
                                                  source: "let x = 1", text: "Why one?")]
        pane.selectModel(provider: .codex, model: "gpt-6-astra")
        return attachments
    }

    func testMixedDraftSurvivesRestartAndIsRestoredOnlyWhenTheUserChooses() async throws {
        let h = try harness()
        let draft = h.root.appendingPathComponent("drafts/conversation.json")
        let first = try await connected(h, draft: draft)
        let attachments = writeMixedDraft(into: first)
        first.stashDraft()
        try await h.until { first.notice?.text.hasPrefix("Stashed the draft.") == true }
        XCTAssertEqual(first.surface.composer.string, "")
        XCTAssertTrue(first.draftAttachments.isEmpty)
        XCTAssertTrue(first.reviewComments.isEmpty)
        let store = try XCTUnwrap(first.stashStore)
        let stashed = try await store.entries()
        let entry = try XCTUnwrap(stashed.first)
        XCTAssertEqual(stashed.count, 1)
        XCTAssertEqual(entry.model, "gpt-6-astra")
        try await first.flushDraft()
        first.dispose()

        // Restart: a new pane over the same storage, with a second draft.
        let second = try await connected(h, draft: draft)
        second.surface.composer.string = "A second draft"
        var questions: [AgentStashQuestion] = []
        second.composerWork.askStash = { questions.append($0); return .cancel }
        second.restoreStash(entry.id)
        try await h.until { !questions.isEmpty && second.composerWork.stashTask == nil }
        XCTAssertEqual(questions, [.occupied("Explain this quote please")])
        XCTAssertEqual(second.surface.composer.string, "A second draft", "Both stay until the user chooses")
        let secondStore = try XCTUnwrap(second.stashStore)
        let afterCancel = try await secondStore.entries()
        XCTAssertEqual(afterCancel.map(\.id), [entry.id])

        second.composerWork.askStash = { _ in .replace }
        second.restoreStash(entry.id)
        try await h.until { second.notice?.text == "Restored the stashed draft." }
        XCTAssertEqual(second.surface.composer.string, "Explain this quote please")
        let storage = try XCTUnwrap(second.surface.composer.textStorage)
        XCTAssertEqual(storage.attribute(.agentAssistantCitation, at: 10, effectiveRange: nil) as? String, citation)
        XCTAssertEqual(second.draftAttachments.map(\.data), attachments.map(\.data))
        XCTAssertEqual(second.reviewComments.map(\.text), ["Why one?"])
        XCTAssertEqual(second.selection.model, "gpt-6-astra")
        let remaining = try await secondStore.entries()
        XCTAssertEqual(remaining.map(\.text), ["A second draft"], "Replacing stashed the draft it replaced")
        // Restoring is durable before the entry leaves the stash.
        let saved = try JSONDecoder().decode(AgentSavedDraft.self, from: Data(contentsOf: draft))
        XCTAssertEqual(saved.text, "Explain this quote please")
        XCTAssertEqual(saved.attachments.count, 2)
        let server = try await h.read()
        XCTAssertTrue(server.items.isEmpty, "Nothing was sent")
    }

    func testUnavailableAttachmentIsIdentifiedAndNothingIsSent() async throws {
        let h = try harness()
        let draft = h.root.appendingPathComponent("drafts/conversation.json")
        let pane = try await connected(h, draft: draft)
        _ = writeMixedDraft(into: pane)
        pane.stashDraft()
        try await h.until { pane.notice?.text.hasPrefix("Stashed the draft.") == true }
        let store = try XCTUnwrap(pane.stashStore)
        let listed = try await store.entries()
        let entry = try XCTUnwrap(listed.first)
        let folder = AgentDraftStashStore.directory(forDraft: draft).appendingPathComponent(entry.id)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("0.bin"))

        var questions: [AgentStashQuestion] = []
        pane.composerWork.askStash = { questions.append($0); return .cancel }
        pane.restoreStash(entry.id)
        try await h.until { !questions.isEmpty && pane.composerWork.stashTask == nil }
        XCTAssertEqual(questions, [.missingAttachments(["Shot.png"])])
        XCTAssertTrue(pane.draftAttachments.isEmpty)
        let kept = try await store.entries()
        XCTAssertEqual(kept.count, 1)

        pane.composerWork.askStash = { _ in .replace }
        pane.restoreStash(entry.id)
        try await h.until { pane.notice?.text.contains("Unavailable and not restored: “Shot.png”") == true }
        XCTAssertEqual(pane.notice?.kind, .warning)
        XCTAssertEqual(pane.draftAttachments.map(\.name), ["Notes.txt"])
        XCTAssertEqual(pane.surface.composer.string, "Explain this quote please")
        let server = try await h.read()
        XCTAssertTrue(server.items.isEmpty, "Restoring never sends")
        XCTAssertNil(h.runtime)
    }

    func testMergeAddsTheStashedDraftAfterTheCurrentOne() async throws {
        let h = try harness()
        let draft = h.root.appendingPathComponent("drafts/conversation.json")
        let pane = try await connected(h, draft: draft)
        pane.surface.composer.string = "/stash Earlier idea"
        pane.send()
        try await h.until { pane.notice?.text.hasPrefix("Stashed the draft.") == true }
        let store = try XCTUnwrap(pane.stashStore)
        let listed = try await store.entries()
        let entry = try XCTUnwrap(listed.first)
        XCTAssertEqual(entry.text, "Earlier idea", "/stash sets aside what follows it")
        pane.surface.composer.string = "Current idea"
        pane.composerWork.askStash = { _ in .merge }
        pane.restoreStash(entry.id)
        try await h.until { pane.notice?.text == "Added the stashed draft to yours." }
        XCTAssertEqual(pane.surface.composer.string, "Current idea\n\nEarlier idea")
        let left = try await store.entries()
        XCTAssertEqual(left.count, 0)
    }

    func testStashIndexToleratesMissingOptionalFieldsAndUnreadableIndexIsPreserved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("st-" + UUID().uuidString.prefix(8))
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        try Data(#"[{"id":"\#(id)","createdAt":"2026-01-02T03:04:05Z","text":"Older stash","futureField":1}]"#.utf8)
            .write(to: directory.appendingPathComponent("index.json"))
        let store = AgentDraftStashStore(directory: directory)
        let restore = try await store.load(id)
        XCTAssertEqual(restore.entry.text, "Older stash")
        XCTAssertTrue(restore.attachments.isEmpty && restore.missing.isEmpty)

        try Data("not json".utf8).write(to: directory.appendingPathComponent("index.json"))
        do { _ = try await store.entries(); XCTFail("An unreadable stash is reported") } catch {
            XCTAssertTrue(error.localizedDescription.contains("preserved"), error.localizedDescription)
        }
        let preserved = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("index.json.unreadable-") }
        XCTAssertEqual(preserved.count, 1)
    }
}
