import AgentCore
import AppKit
import XCTest
@testable import AgentUI

/// Running and finished agents in the pane, their steps, and the notices around them.
@MainActor
final class AgentSubagentPaneTests: XCTestCase {
    private func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }

    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition not met", file: file, line: line)
    }

    func testFinishedAgentsStayWithTheirOutcomeUntilDismissedAndOldServersStillShowRunningOnes() throws {
        let view = AgentSubagentsView(frame: NSRect(x: 0, y: 0, width: 700, height: 120))
        let start = Date().addingTimeInterval(-65)
        let running = AgentSubagent(id: "a", toolUseID: "t-a", description: "Audit fixtures", agentType: "Explore",
                                    activity: "Reading tests", startedAt: start)
        var failed = AgentSubagent(id: "b", toolUseID: "t-b", description: "Run checks", status: .failed,
                                   activity: "Build broke", startedAt: start, finishedAt: start.addingTimeInterval(12))
        view.update([running, failed])
        XCTAssertEqual(view.shown.map(\.id), ["a", "b"])
        view.layoutSubtreeIfNeeded()
        let labels = all(view).compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertTrue(labels.contains("Explore · Reading tests"), "\(labels)")
        XCTAssertTrue(labels.contains { $0.hasSuffix("1m 05s") || $0.hasSuffix("1m 06s") }, "A running agent shows its elapsed time: \(labels)")
        XCTAssertTrue(labels.contains("Failed · Build broke"))
        XCTAssertTrue(labels.contains("12s"), "A finished agent shows how long it ran")
        let failedLabel = try XCTUnwrap(all(view).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Failed · Build broke" })
        XCTAssertEqual(failedLabel.textColor, AgentTheme.shared.danger, "Failure is obvious")
        view.dismiss("b")
        XCTAssertEqual(view.shown.map(\.id), ["a"])
        failed.activity = "Still broke"
        view.update([running, failed])
        XCTAssertEqual(view.shown.map(\.id), ["a"], "A dismissed agent stays dismissed")
        view.update([running])
        XCTAssertEqual(view.shown.map(\.id), ["a"], "A server that predates finished agents sends running ones only")
    }

    func testRowOpensStepsAndItsMenuStillRevealsTheToolRow() throws {
        let row = AgentSubagentRow()
        let agent = AgentSubagent(id: "a", toolUseID: "tool", description: "Audit")
        row.show(agent)
        var opened: AgentSubagent?
        var revealed: String?
        row.onOpen = { opened = $0 }
        row.onPress = { revealed = $0 }
        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertEqual(opened?.id, "a")
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(row.menu(for: event))
        let item = try XCTUnwrap(menu.items.first { $0.title == "Show in Conversation" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(revealed, "tool")
    }

    func testStepsWindowFollowsTheAgentThroughSnapshotsAndExplainsAnOldServer() async throws {
        _ = NSApplication.shared
        let session = SessionId(), project = ProjectId()
        var agent = AgentSubagent(id: "a", toolUseID: "tool", description: "Audit", background: true, steps: 1)
        var snapshot = AgentChatSnapshot(session: session, project: project, provider: .claude, providerSession: "p",
                                         status: .idle, revision: 2)
        snapshot.subagents = [agent]
        var steps = [AgentChatItem(id: "s1", kind: .tool, text: "Bash", tool: .init(name: "Bash", category: .command,
                                                                                   input: #"{"command":"ls"}"#, status: .completed))]
        var reads = 0
        let pane = AgentPaneController(session: session, project: project, provider: .claude) { _ in snapshot }
        defer { pane.dispose() }
        pane.conversationRequest = { request in
            // A server without incremental reads: snapshots come whole.
            guard case .subagentSteps(_, let id) = request else { throw ErrorReply(code: .unsupported, message: "") }
            reads += 1
            return .subagentSteps(AgentSubagentSteps(toolUseID: id, items: steps))
        }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        pane.openSubagentSteps(agent)
        let window = try XCTUnwrap(pane.subagentWindows["tool"])
        try await wait { window.items.count == 1 }
        XCTAssertEqual(reads, 1)
        steps.append(AgentChatItem(id: "s2", kind: .assistant, text: "Found it"))
        agent.steps = 2
        snapshot.subagents = [agent]
        snapshot.revision += 1
        pane.sessionChanged(session: session, revision: snapshot.revision)
        try await wait { window.items.count == 2 }
        XCTAssertEqual(reads, 2, "A step count change reads them again; nothing polls")
        window.close()
        XCTAssertNil(pane.subagentWindows["tool"])

        pane.conversationRequest = { _ in throw ErrorReply(code: .unsupported, message: "") }
        pane.openSubagentSteps(agent)
        let old = try XCTUnwrap(pane.subagentWindows["tool"])
        try await wait {
            self.all(try! XCTUnwrap(old.window?.contentView)).contains { ($0 as? NSTextField)?.stringValue.contains("conversation backend") == true }
        }
        old.close()
    }

    func testAgentReportRendersAsMarkdown() throws {
        let view = AgentToolDisclosure(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let item = AgentChatItem(id: "agent", kind: .tool, text: "Agent", tool: .init(
            name: "Agent", category: .subagent, input: #"{"description":"Audit","prompt":"Look"}"#,
            output: "## Findings\n\n- **One** issue", status: .completed, presentation: .dynamicTool))
        view.onOpenSubagent = { _ in }
        view.update(item, expanded: true, theme: .shared)
        view.layoutSubtreeIfNeeded()
        let text = all(view).compactMap { $0 as? NSTextView }.map(\.string)
        XCTAssertTrue(text.contains { $0.contains("Findings") && !$0.contains("##") && !$0.contains("**") }, "\(text)")
        XCTAssertTrue(all(view).contains { ($0 as? NSButton)?.title == "Show steps" && !$0.isHidden })
    }

    func testChangingTheModelWhileAgentsRunAsksFirst() async throws {
        _ = NSApplication.shared
        let session = SessionId(), project = ProjectId()
        var snapshot = AgentChatSnapshot(session: session, project: project, provider: .claude, providerSession: "p",
                                         status: .idle, revision: 2)
        snapshot.subagents = [AgentSubagent(id: "a", description: "Audit", background: true)]
        let pane = AgentPaneController(session: session, project: project, provider: .claude) { _ in snapshot }
        defer { pane.dispose() }
        var asked: Int?
        var answer = false
        pane.confirmAgentRestart = { count in asked = count; return answer }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        pane.selectModel(provider: .claude, model: "claude-opus-5-5")
        try await wait { asked != nil }
        XCTAssertEqual(asked, 1)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(pane.selection.model, "Cancelling keeps the model")
        answer = true
        pane.selectModel(provider: .claude, model: "claude-opus-5-5")
        try await wait { pane.selection.model == "claude-opus-5-5" }
    }



    func testOlderServerNoticeIsADismissibleNoticeOncePerConnection() async throws {
        _ = NSApplication.shared
        let session = SessionId(), project = ProjectId()
        let snapshot = AgentChatSnapshot(session: session, project: project, provider: .claude, status: .idle, revision: 2)
        let pane = AgentPaneController(session: session, project: project, provider: .claude) { _ in snapshot }
        defer { pane.dispose() }
        pane.connectionNotice = { "This backend is older than the host application." }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        XCTAssertEqual(pane.notice?.kind, .warning)
        XCTAssertFalse(pane.surface.dismissNotice.isHidden)
        pane.dismissNotice()
        pane.refresh()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(pane.notice, "Said once per connection")
    }

    func testTurnTheAgentBeganItselfReadsAsANoteNotAPrompt() throws {
        let document = AgentTranscriptDocument(frame: .zero)
        let anchor = AgentChatItem(id: "auto", kind: .user, text: "Background agent “Audit” finished",
                                   workContext: .init(itemType: AgentChatItem.providerTurnType))
        let items = [AgentChatItem(id: "u", kind: .user, text: "Launch it"),
                     AgentChatItem(id: "a1", kind: .assistant, text: "Launched."),
                     anchor,
                     AgentChatItem(id: "a2", kind: .assistant, text: "It finished.", isComplete: false)]
        document.update(items, omittedCount: 0, turns: [AgentChatTurn(userItemID: "u", startedAt: Date(), completedAt: Date(), status: .idle),
                                                        AgentChatTurn(userItemID: "auto", startedAt: Date())])
        document.reflow(viewportWidth: 700)
        XCTAssertTrue(document.subviews.contains { $0 is AgentNoticeRow })
        XCTAssertNotNil(document.frameForEntry("working:auto"), "The agent's own turn shows the working line")
        XCTAssertEqual(AgentPromptNavigation.entries(items).map(\.id), ["u"])
    }
}

/// Reverting a turn from the changed-files card.
@MainActor
final class AgentRevertPaneTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Condition not met")
    }

    func testRevertConfirmsThenAsksAgainForFilesChangedSince() async throws {
        _ = NSApplication.shared
        let session = SessionId(), project = ProjectId()
        let snapshot = AgentChatSnapshot(session: session, project: project, provider: .claude, status: .idle, revision: 2)
        let pane = AgentPaneController(session: session, project: project, provider: .claude) { _ in snapshot }
        defer { pane.dispose() }
        var asked: [String] = []
        pane.confirmDestructive = { title, _, _ in asked.append(title); return true }
        var requests: [AgentConversationRequest] = []
        pane.conversationRequest = { request in
            requests.append(request)
            guard case .revert(_, _, _, let force) = request else { throw ModelError("unexpected") }
            return .revert(force ? AgentRevertReply(reverted: ["a.swift", "b.swift"]) : AgentRevertReply(conflicts: ["b.swift"]))
        }
        let checkpoint = AgentTurnCheckpoint(id: UUID().uuidString, files: [.init(path: "a.swift", additions: 1, deletions: 0),
                                                                            .init(path: "b.swift", additions: 2, deletions: 1)],
                                             totalFiles: 2, additions: 3, deletions: 1)
        pane.revertTurn(checkpoint, paths: nil)
        try await wait { pane.notice?.text == "Reverted 2 files." }
        XCTAssertEqual(asked, ["Revert 2 files?", "1 file changed after this turn"])
        XCTAssertEqual(requests, [.revert(session: session, checkpoint: checkpoint.id, paths: nil, force: false),
                                  .revert(session: session, checkpoint: checkpoint.id, paths: nil, force: true)])

        asked = []
        requests = []
        pane.confirmDestructive = { title, _, _ in asked.append(title); return false }
        pane.revertTurn(checkpoint, paths: ["a.swift"])
        try await wait { asked == ["Revert “a.swift”?"] }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(requests.isEmpty, "Cancelling sends nothing")

        pane.confirmDestructive = { _, _, _ in true }
        pane.conversationRequest = { _ in throw ErrorReply(code: .unsupported, message: "") }
        pane.revertTurn(checkpoint, paths: nil)
        try await wait { pane.notice?.text.contains("conversation backend") == true }
    }

    func testChangedFilesCardOffersRevertForTheTurnAndEachFile() throws {
        let row = AgentChangedFilesRow(frame: NSRect(x: 0, y: 0, width: 600, height: 120))
        var reverted: [String]??
        row.onRevert = { _, paths in reverted = paths }
        row.checkpoint = AgentTurnCheckpoint(id: UUID().uuidString, files: [.init(path: "a.swift", additions: 1, deletions: 0)],
                                             totalFiles: 1, additions: 1, deletions: 0)
        row.layoutRow(width: 600)
        let button = try XCTUnwrap(row.subviews.compactMap { $0 as? PillButton }.first { $0.title == "Revert" })
        XCTAssertFalse(button.isHidden)
        button.perform()
        XCTAssertEqual(reverted, .some(nil))
        let file = try XCTUnwrap(row.subviews.compactMap { $0 as? PillButton }.first { $0.menu != nil })
        let item = try XCTUnwrap(file.menu?.items.first { $0.title == "Revert File…" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(reverted, .some(["a.swift"]))
    }
}

@MainActor
final class AgentForkPaneTests: XCTestCase {
    func testForkFromHereOpensTheForkBesideAndOnlyClaudeOffersIt() async throws {
        _ = NSApplication.shared
        let session = SessionId(), project = ProjectId()
        let snapshot = AgentChatSnapshot(session: session, project: project, provider: .claude, status: .idle, revision: 2,
                                         items: [.init(id: "u1", kind: .user, text: "First"), .init(id: "a1", kind: .assistant, text: "Done")])
        let pane = AgentPaneController(session: session, project: project, provider: .claude) { _ in snapshot }
        defer { pane.dispose() }
        var shown: AgentChatSnapshot?
        pane.showConversation = { shown = $0 }
        var asked: AgentConversationRequest?
        pane.conversationRequest = { request in
            asked = request
            guard case .fork(let id, _, _, _) = request else { throw ModelError("unexpected") }
            return .forked(AgentChatSnapshot(session: id, project: project, provider: .claude))
        }
        pane.fork(before: snapshot.items[0])
        for _ in 0..<200 where shown == nil { try await Task.sleep(for: .milliseconds(10)) }
        guard case .fork(let id, let from, _, let at)? = asked else { return XCTFail("No fork request") }
        XCTAssertEqual(from, session)
        XCTAssertEqual(at, "u1")
        XCTAssertEqual(shown?.session, id)

        let document = AgentTranscriptDocument(frame: .zero)
        document.onForkPrompt = { _ in }
        func forkButtonShown(_ provider: AgentChatProvider) -> Bool {
            document.provider = provider
            document.update(snapshot.items, omittedCount: 0)
            document.reflow(viewportWidth: 700)
            let row = document.subviews.compactMap { $0 as? AgentMessageRow }.first { $0.assistantItem == nil }
            return row.map { all($0).contains { ($0 as? NSButton)?.accessibilityLabel() == "Fork from here" && !$0.isHidden } } ?? false
        }
        XCTAssertTrue(forkButtonShown(.claude))
        XCTAssertFalse(forkButtonShown(.codex), "Codex forks only whole threads")
    }

    private func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
}

@MainActor
final class AgentDiffEditorTests: XCTestCase {
    func testDiffWindowOpensTheFileAtItsFirstChangedLine() async throws {
        _ = NSApplication.shared
        let checkpoint = UUID().uuidString
        let window = AgentCheckpointDiffWindow(session: SessionId(), checkpoint: checkpoint, path: "a.swift", theme: .shared) { request in
            .init(checkpoint: checkpoint, files: [.init(path: "a.swift", additions: 1, deletions: 1)], totalFiles: 1, path: request.path,
                  diff: request.path == nil ? nil : AgentToolDiff.parse("@@ -10,2 +10,2 @@\n context\n-old\n+new"))
        }
        defer { window.close() }
        var opened: (String, Int?)?
        window.onOpenFile = { opened = ($0, $1) }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let button = try XCTUnwrap(all(try XCTUnwrap(window.window?.contentView)).compactMap { $0 as? PillButton }.first { $0.title == "Open in Editor" })
        XCTAssertFalse(button.isHidden)
        for _ in 0..<300 {
            button.perform()
            if opened?.1 != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(opened?.0, "a.swift")
        XCTAssertEqual(opened?.1, 10)
    }

}

extension AgentSubagentPaneTests {
    /// T1: the window reads again on a new steps revision even at the same count, on the
    /// agent ending, and as the server's window of steps rolls over; reads due while one is
    /// in flight become one read after it. T5: earlier steps page in above, steps the server
    /// dropped are counted, and an agent whose steps weren't saved says so.
    func testStepsWindowFollowsRevisionsCoalescesReadsAndPagesEarlierSteps() async throws {
        _ = NSApplication.shared
        let session = SessionId(), project = ProjectId()
        var agent = AgentSubagent(id: "a", toolUseID: "tool", description: "Audit", steps: 1, stepsRevision: 1)
        var snapshot = AgentChatSnapshot(session: session, project: project, provider: .claude, providerSession: "p",
                                         status: .working, revision: 2)
        snapshot.subagents = [agent]
        let running = AgentChatItem(id: "t1", kind: .tool, text: "Bash", isComplete: false,
                                    tool: .init(name: "Bash", category: .command, input: #"{"command":"swift test"}"#, status: .running))
        var newest = AgentSubagentSteps(toolUseID: "tool", items: [running], revision: 1, start: 0, total: 1, omitted: 0)
        var allSteps: [AgentChatItem] = [running]
        var gate: CheckedContinuation<Void, Never>?
        var gateNext = false
        var pages: [Int] = []
        let pane = AgentPaneController(session: session, project: project, provider: .claude) { _ in snapshot }
        defer { pane.dispose() }
        pane.conversationRequest = { request in
            switch request {
            case .subagentSteps:
                // A reply holds the steps as they were when the server read them.
                let reply = newest
                if gateNext { gateNext = false; await withCheckedContinuation { gate = $0 } }
                return .subagentSteps(reply)
            case .subagentStepsPage(_, _, let before, _):
                pages.append(before)
                let items = Array(allSteps.prefix(before))
                return .subagentSteps(AgentSubagentSteps(toolUseID: "tool", items: items, revision: newest.revision,
                                                         start: 0, total: newest.total, omitted: 0))
            default: throw ErrorReply(code: .unsupported, message: "")
            }
        }
        func publish(_ change: () -> Void) async throws {
            change()
            snapshot.subagents = [agent]
            snapshot.revision += 1
            let revision = snapshot.revision
            pane.sessionChanged(session: session, revision: revision)
            try await self.wait { pane.snapshot?.revision == revision }
        }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        pane.openSubagentSteps(agent)
        let window = try XCTUnwrap(pane.subagentWindows["tool"])
        try await wait { window.items.count == 1 }
        XCTAssertEqual(window.readCount, 1, "Opening reads once")

        // The running tool completes in place: same count, new revision.
        var completed = running
        completed.isComplete = true
        completed.tool?.status = .completed
        completed.tool?.output = "All tests passed"
        gateNext = true
        try await publish {
            allSteps = [completed]
            newest = AgentSubagentSteps(toolUseID: "tool", items: allSteps, revision: 2, start: 0, total: 1, omitted: 0)
            agent.stepsRevision = 2
        }
        try await wait { gate != nil }
        XCTAssertEqual(window.readCount, 2)
        // Two more revisions arrive while that read is in flight.
        for revision in [3, 4] as [UInt64] {
            try await publish {
                allSteps = [completed, AgentChatItem(id: "r\(revision)", kind: .assistant, text: "Revision \(revision)")]
                newest = AgentSubagentSteps(toolUseID: "tool", items: allSteps, revision: revision, start: 0, total: 2, omitted: 0)
                agent.stepsRevision = revision
                agent.steps = 2
            }
        }
        gate?.resume(); gate = nil
        try await wait { window.loadedRevision == 4 }
        XCTAssertEqual(window.readCount, 3, "Reads due during a read become one")
        XCTAssertEqual(window.items.first?.tool?.output, "All tests passed")
        XCTAssertEqual(window.items.first?.isComplete, true)

        // The server's window of 200 rolls over at the same size.
        try await publish {
            allSteps = [completed] + (0..<200).map { AgentChatItem(id: "s\($0)", kind: .assistant, text: "Step \($0)") }
            newest = AgentSubagentSteps(toolUseID: "tool", items: Array(allSteps.suffix(200)), revision: 5, start: 1, total: 201, omitted: 0)
            agent.stepsRevision = 5
            agent.steps = 201
        }
        try await wait { window.loadedRevision == 5 }
        XCTAssertEqual(window.items.first?.id, "s0")
        try await publish {
            allSteps.append(AgentChatItem(id: "s200", kind: .assistant, text: "Step 200"))
            newest = AgentSubagentSteps(toolUseID: "tool", items: Array(allSteps.suffix(200)), revision: 6, start: 2, total: 202, omitted: 0)
            agent.stepsRevision = 6
            agent.steps = 202
        }
        try await wait { window.loadedRevision == 6 }
        XCTAssertEqual(window.items.count, 200)
        XCTAssertEqual(window.items.last?.id, "s200")
        let reads = window.readCount
        // Ending reads once more even when the revision didn't move.
        try await publish { agent.status = .completed }
        try await wait { window.readCount == reads + 1 }

        // Earlier steps load above the newest page.
        XCTAssertNotNil(window.transcript.onEarlier)
        window.loadEarlier()
        try await wait { window.earlierStart == 0 }
        XCTAssertEqual(pages, [2])
        XCTAssertEqual(window.items.prefix(2).map(\.id), ["t1", "s0"])
        XCTAssertEqual(window.items.count, 202)
        XCTAssertNil(window.transcript.onEarlier, "The first step is shown")
        window.close()

        // Steps the server dropped are counted; there is nothing to load for them.
        newest = AgentSubagentSteps(toolUseID: "tool", items: [completed], revision: 9, start: 30, total: 31, omitted: 30)
        pane.openSubagentSteps(agent)
        let trimmed = try XCTUnwrap(pane.subagentWindows["tool"])
        try await wait { trimmed.loadedRevision == 9 }
        XCTAssertNil(trimmed.transcript.onEarlier)
        let labels = all(try XCTUnwrap(trimmed.window?.contentView)).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains("30 earlier steps weren't kept by the server."), "\(labels)")
        trimmed.close()

        // A child the server never saved, as after an older server's restart.
        newest = AgentSubagentSteps(toolUseID: "tool", items: [], unavailable: true)
        pane.openSubagentSteps(agent)
        let unsaved = try XCTUnwrap(pane.subagentWindows["tool"])
        try await wait { unsaved.message.stringValue == "This agent's steps weren't saved, so they can't be shown." }
        unsaved.close()
    }
}
