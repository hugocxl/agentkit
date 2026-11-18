import AgentCore
import AppKit
import XCTest
@testable import AgentUI

@MainActor
final class AgentRequestDecisionTests: XCTestCase {
    @MainActor
    private final class Backend {
        let session = SessionId()
        let project = ProjectId()
        var requests: [AgentChatRequest] = []
        var library: [AgentConversationLibraryRequest] = []
        lazy var snapshot = AgentChatSnapshot(session: session, project: project, provider: .codex)

        func request(_ request: AgentChatRequest) async throws -> AgentChatSnapshot {
            requests.append(request)
            switch request {
            case .scheduleRetry(_, _, let enabled):
                let index = snapshot.turns?.indices.last ?? 0
                snapshot.turns?[index].rateLimit?.retryAt = enabled ? snapshot.turns?[index].rateLimit?.resetsAt : nil
                snapshot.revision += 1
            default: break
            }
            return snapshot
        }

        func controller() -> AgentPaneController {
            AgentPaneController(session: session, project: project, provider: .codex) { [self] in try await request($0) }
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The pane did not settle")
    }

    private func pending(_ decisions: [AgentApprovalDecision]) -> AgentChatItem {
        AgentChatItem(id: "4", kind: .approval, text: "make", isComplete: false,
                      interaction: AgentApprovalRequest(method: "item/commandExecution/requestApproval", decisions: decisions))
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    func testShortcutsBindOnlyToTheExactOfferedActionAndCardsShowTheOffer() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane.surface
        defer { window.contentView = nil; window.close() }
        // A cancel-only request: neither Allow nor Deny has its exact action.
        backend.snapshot.status = .waiting
        backend.snapshot.items = [AgentChatItem(kind: .user, text: "go"), pending([.init(id: "cancel", kind: .cancel, label: "Decline and stop")])]
        pane.refresh()
        try await wait { pane.snapshot?.items.count == 2 }
        pane.surface.layoutSubtreeIfNeeded()
        XCTAssertFalse(pane.performApprovalShortcut(allow: true))
        XCTAssertFalse(pane.performApprovalShortcut(allow: false))
        let buttons = descendants(pane.surface).compactMap { $0 as? PillButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
        XCTAssertTrue(buttons.contains { $0.title == "Decline and stop" })
        XCTAssertFalse(buttons.contains { $0.title == "Allow" || $0.title == "Deny" }, "Plain Allow and Deny give way to the offer")
        try XCTUnwrap(buttons.first { $0.title == "Decline and stop" }).onPress?()
        try await wait { backend.requests.contains(.decide(session: backend.session, request: "4", decision: "cancel")) }

        // Without one-time acceptance, Allow still doesn't bind; Deny binds to Decline.
        backend.snapshot.items[1] = pending([.init(id: "acceptForSession", kind: .allowSession, label: "Allow for session"),
                                             .init(id: "decline", kind: .decline, label: "Decline")])
        backend.snapshot.revision += 1
        pane.refresh()
        try await wait { pane.snapshot?.items.last?.interaction?.decisions.count == 2 }
        XCTAssertFalse(pane.performApprovalShortcut(allow: true))
        XCTAssertTrue(pane.performApprovalShortcut(allow: false))
        try await wait { backend.requests.contains(.decide(session: backend.session, request: "4", decision: "decline")) }

        // A legacy approval keeps its plain Allow.
        backend.snapshot.items[1] = AgentChatItem(id: "5", kind: .approval, text: "Bash", isComplete: false)
        backend.snapshot.revision += 1
        pane.refresh()
        try await wait { pane.snapshot?.items.last?.id == "5" }
        XCTAssertTrue(pane.performApprovalShortcut(allow: true))
        try await wait { backend.requests.contains { if case .approve(_, "5", true, _, _) = $0 { return true }; return false } }
    }

    func testSettledCardsSayHowTheRequestEnded() {
        var offer = AgentApprovalRequest(decisions: [.init(id: "accept", kind: .allowOnce, label: "Allow once")],
                                         origin: AgentRequestOrigin(threadID: "child", agentID: "child", toolUseID: "spawn"))
        let pendingItem = AgentChatItem(id: "1", kind: .approval, text: "npm test", isComplete: false, interaction: offer)
        XCTAssertTrue(AgentMessageRow.requestText(pendingItem).contains("Asked by a child agent"))
        offer.outcome = .expired
        XCTAssertEqual(AgentMessageRow.settledTitle(offer), "Expired")
        offer.outcome = .resolvedElsewhere
        XCTAssertEqual(AgentMessageRow.settledTitle(offer), "Resolved elsewhere")
        XCTAssertEqual(AgentMessageRow.settledTitle(nil), "Decision recorded")
    }

    /// Select an option, type custom text, clear it, select again, then submit: what shows
    /// selected is what is sent, and a secret stays out of the draft.
    func testASingleChoiceIsEitherItsOptionOrWrittenText() throws {
        let form = AgentQuestionnaire(questions: [
            .init(id: "plan", title: "Plan", options: [.init(label: "Small"), .init(label: "Large")]),
            .init(id: "tags", title: "Tags", options: [.init(label: "ui"), .init(label: "api")], multiple: true, required: false),
            .init(id: "token", title: "Token", secret: true, required: false)
        ])
        let item = AgentChatItem(id: "q", kind: .approval, text: "Questions", isComplete: false, questionnaire: form)
        let view = AgentQuestionView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
        view.update(item, enabled: true)
        let radios = descendants(view).compactMap { $0 as? NSButton }.filter { ["Small", "Large"].contains($0.title) }
        let checks = descendants(view).compactMap { $0 as? NSButton }.filter { ["ui", "api"].contains($0.title) }
        let fields = descendants(view).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        let planField = try XCTUnwrap(fields.first { !($0 is NSSecureTextField) && $0.placeholderString == "Or write your own answer" })
        let secret = try XCTUnwrap(fields.first { $0 is NSSecureTextField })
        func type(_ text: String, in field: NSTextField) {
            field.stringValue = text
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        }
        let small = try XCTUnwrap(radios.first { $0.title == "Small" })
        small.performClick(nil)
        XCTAssertEqual(view.answers["plan"], ["Small"])
        type("Medium, please", in: planField)
        XCTAssertEqual(small.state, .off, "Writing an answer clears the selected option")
        XCTAssertEqual(view.answers["plan"], ["Medium, please"])
        type("", in: planField)
        XCTAssertTrue(radios.allSatisfy { $0.state == .off })
        XCTAssertEqual(view.answers["plan"], [])
        small.performClick(nil)
        XCTAssertEqual(planField.stringValue, "")
        XCTAssertEqual(view.answers["plan"], ["Small"])
        // Multiple choice keeps options and written text together.
        try XCTUnwrap(checks.first { $0.title == "api" }).performClick(nil)
        let tagsField = try XCTUnwrap(fields.first { !($0 is NSSecureTextField) && $0 !== planField })
        type("docs", in: tagsField)
        XCTAssertEqual(view.answers["tags"], ["api", "docs"])
        type("hunter2", in: secret)
        XCTAssertEqual(view.savedAnswers["q"]?["token"], nil, "A secret stays out of drafts")
        var sent: [String: [String]]?
        view.onAnswer = { _, answers, _ in sent = answers }
        XCTAssertTrue(view.submitAnswers())
        XCTAssertEqual(sent?["plan"], ["Small"])
        XCTAssertEqual(sent?["token"], ["hunter2"])

        // A restored draft that holds written text shows no selected option.
        let restored = AgentQuestionView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
        restored.update(item, enabled: true)
        restored.restore(["q": ["plan": ["Medium"]]])
        XCTAssertEqual(restored.answers["plan"], ["Medium"])
        XCTAssertTrue(descendants(restored).compactMap { $0 as? NSButton }.filter { ["Small", "Large"].contains($0.title) }.allSatisfy { $0.state == .off })
    }

    func testAnMCPFormAnswersWithItsOfferedDecisions() throws {
        let form = AgentQuestionnaire(questions: [.init(id: "title", title: "Title")])
        let offer = AgentApprovalRequest(method: "mcpServer/elicitation/request", decisions: [
            .init(id: "accept", kind: .submit, label: "Submit"), .init(id: "decline", kind: .decline, label: "Decline"),
            .init(id: "cancel", kind: .cancel, label: "Cancel")])
        let item = AgentChatItem(id: "e", kind: .approval, text: "Title?", isComplete: false, questionnaire: form, interaction: offer)
        let view = AgentQuestionView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.update(item, enabled: true)
        var decisions: [(String, [String: [String]]?)] = []
        view.onDecision = { _, decision, answers in decisions.append((decision, answers)) }
        view.onAnswer = { _, _, _ in XCTFail("Offered decisions answer the form") }
        let field = try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextField }.first(where: \.isEditable))
        field.stringValue = "Bug"
        XCTAssertTrue(view.submitAnswers())
        let buttons = descendants(view).compactMap { $0 as? PillButton }
        try XCTUnwrap(buttons.first { $0.title == "Decline" && !$0.isHidden }).onPress?()
        try XCTUnwrap(buttons.first { $0.title == "Cancel" }).onPress?()
        XCTAssertEqual(decisions.map(\.0), ["accept", "decline", "cancel"])
        XCTAssertEqual(decisions.first?.1, ["title": ["Bug"]])
        XCTAssertNil(decisions[1].1)
    }

    func testUsageLimitShowsItsResetAndRetriesThroughTheBackend() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        let reset = Date().addingTimeInterval(3600)
        let user = AgentChatItem(id: UUID().uuidString, kind: .user, text: "build it")
        backend.snapshot.status = .failed
        backend.snapshot.items = [user, AgentChatItem(kind: .notice, text: "You've hit your usage limit.")]
        var turn = AgentChatTurn(userItemID: user.id, startedAt: Date(), completedAt: Date(), status: .failed, outcome: .failed)
        turn.rateLimit = AgentTurnRateLimit(resetsAt: reset, message: "Usage limit reached",
                                           retryPromptID: AgentTurnRateLimit.retryPromptID(session: backend.session, turn: user.id))
        backend.snapshot.turns = [turn]
        pane.refresh()
        try await wait { pane.snapshot?.turns?.first?.rateLimit != nil && !pane.surface.retryTurn.isHidden }
        XCTAssertTrue(pane.surface.feedback.stringValue.hasPrefix("Usage limit reached · Resets at"))
        XCTAssertFalse(pane.surface.resumeAtReset.isHidden)
        XCTAssertEqual(pane.surface.resumeAtReset.title, "Resume at Reset")
        pane.surface.resumeAtReset.onPress?()
        try await wait { pane.surface.resumeAtReset.title == "Cancel Scheduled Retry" }
        XCTAssertTrue(pane.surface.feedback.stringValue.contains("Sends again at"))
        pane.surface.resumeAtReset.onPress?()
        try await wait { pane.surface.resumeAtReset.title == "Resume at Reset" }
        pane.surface.retryTurn.onPress?()
        try await wait { backend.requests.contains(.retryTurn(session: backend.session, turn: user.id)) }
        XCTAssertEqual(backend.requests.filter { if case .scheduleRetry = $0 { return true }; return false },
                       [.scheduleRetry(session: backend.session, turn: user.id, enabled: true),
                        .scheduleRetry(session: backend.session, turn: user.id, enabled: false)])
        XCTAssertFalse(backend.requests.contains { if case .submit = $0 { return true }; return false },
                       "The client never submits a fresh copy that could double the delivery")
    }

    func testHistoryReopensAKeptConversationAndDeletesOnlyAfterConfirming() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        let kept = AgentSavedConversation(session: SessionId(), project: backend.project, provider: .codex, title: "Old work",
                                          origin: .closed, closedAt: Date(), messages: 4)
        var reopened = AgentChatSnapshot(session: kept.session, project: backend.project, provider: .codex)
        reopened.status = .idle
        pane.library = { [backend] request in
            backend.library.append(request)
            switch request {
            case .list: return .list([kept])
            case .reopen: return .snapshot(reopened)
            case .delete(let session, _): return .deleted(session)
            case .archive: return .snapshot(reopened)
            }
        }
        var shown: [SessionId] = []
        pane.showConversation = { shown.append($0.session) }
        var action = AgentKeptAction.reopen
        pane.chooseKeptAction = { _ in action }
        var confirmed = false
        pane.confirmDestructive = { _, _, _ in confirmed }
        pane.refresh()
        try await wait { pane.snapshot != nil }

        pane.openKept(kept)
        try await wait { shown == [kept.session] }
        XCTAssertEqual(backend.library, [.reopen(session: kept.session)])

        action = .delete
        pane.openKept(kept)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(backend.library.count, 1, "Nothing is deleted without the second confirmation")
        confirmed = true
        try await wait { pane.historyPicker == nil }
        pane.openKept(kept)
        try await wait { backend.library.count == 2 }
        XCTAssertEqual(backend.library.last, .delete(session: kept.session,
                                                     confirmation: AgentConversationLibraryRequest.deleteConfirmation(for: kept.session)))
    }
}
