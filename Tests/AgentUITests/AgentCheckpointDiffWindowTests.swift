import AgentCore
import AppKit
import XCTest
@testable import AgentUI

private actor CheckpointDiffGate {
    var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func fetch(_ request: AgentCheckpointRequest) async -> AgentCheckpointReply {
        let files: [AgentTurnCheckpoint.File] = [
            .init(path: "first.swift", additions: 1, deletions: 0),
            .init(path: "second.swift", additions: 1, deletions: 0)
        ]
        if request.path == "first.swift" {
            waiting = true
            await withCheckedContinuation { continuation = $0 }
        }
        return .init(checkpoint: request.checkpoint, files: files, totalFiles: 2, path: request.path,
                     diff: request.path.map { .init(rows: [.init(kind: .addition, newLineNumber: 1, text: "+" + $0)], additions: 1) })
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
final class AgentCheckpointDiffWindowTests: XCTestCase {
    func testHistoricalDiffControlsUseTheConversationsLightAppearance() {
        _ = NSApplication.shared
        let theme = AgentTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: false)
        let controller = AgentCheckpointDiffWindow(session: SessionId(), checkpoint: "turn", path: nil, theme: theme) { request in
            .init(checkpoint: request.checkpoint, files: [], totalFiles: 0)
        }
        defer { controller.close() }
        XCTAssertEqual(controller.window?.appearance?.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        XCTAssertEqual(controller.window?.contentView?.appearance?.bestMatch(from: [.aqua, .darkAqua]), .aqua)
    }

    func testSlowPreviousSelectionCannotReplaceTheSelectedFile() async throws {
        _ = NSApplication.shared
        let gate = CheckpointDiffGate()
        let controller = AgentCheckpointDiffWindow(session: SessionId(), checkpoint: UUID().uuidString,
            path: "first.swift", theme: AgentTheme(systemIsDark: false), fetch: { await gate.fetch($0) })
        defer { controller.close() }
        for _ in 0..<100 {
            if await gate.waiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await gate.waiting
        XCTAssertTrue(waiting)
        let content = try XCTUnwrap(controller.window?.contentView)
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        let diff = try XCTUnwrap(descendants(content).compactMap { $0 as? DiffRowsView }.first)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        for _ in 0..<100 where diff.document == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(diff.document?.rows.last?.text, "+second.swift")
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(diff.document?.rows.last?.text, "+second.swift")
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    // MARK: Context, saved comments and reveal

    /// A historical file of `lines` lines whose line `changed` the turn rewrote, as a runtime
    /// that reads context from the checkpoint answers; `honorsContext` false answers as an
    /// older runtime, with the usual three lines.
    private final class HistoricalDiffs: @unchecked Sendable {
        var requests: [AgentCheckpointRequest] = []
        var honorsContext = true
        let files: [AgentTurnCheckpoint.File] = [
            .init(path: "file.swift", additions: 1, deletions: 1),
            .init(path: "gone.swift", additions: 0, deletions: 3),
            .init(path: "big.swift", additions: 5, deletions: 0),
            .init(path: "logo.png", additions: nil, deletions: nil)
        ]

        func reply(_ request: AgentCheckpointRequest) -> AgentCheckpointReply {
            requests.append(request)
            let context = honorsContext ? (request.context ?? 3) : 3
            var diff: GitDiff?
            switch request.path {
            case "file.swift"?:
                var rows: [GitDiffRow] = []
                for line in UInt64(max(1, 20 - context))..<20 { rows.append(.init(kind: .context, oldLineNumber: line, newLineNumber: line, text: " old \(line)")) }
                rows.append(.init(kind: .deletion, oldLineNumber: 20, text: "-old 20"))
                rows.append(.init(kind: .addition, newLineNumber: 20, text: "+new 20"))
                for line in 21...UInt64(min(40, 20 + context)) { rows.append(.init(kind: .context, oldLineNumber: line, newLineNumber: line, text: " old \(line)")) }
                diff = GitDiff(rows: rows, additions: 1, deletions: 1)
            case "gone.swift"?:
                diff = GitDiff(rows: [GitDiffRow(kind: .hunk, text: "@@")] + (UInt64(1)...3).map { (line: UInt64) in GitDiffRow(kind: .deletion, oldLineNumber: line, text: "-gone \(line)") },
                               deletions: 3)
            case "big.swift"?:
                diff = GitDiff(rows: [GitDiffRow(kind: .hunk, text: "@@")] + (UInt64(1)...5).map { (line: UInt64) in GitDiffRow(kind: .addition, newLineNumber: line, text: "+big \(line)") },
                               additions: 5, truncated: true)
            case "logo.png"?:
                diff = GitDiff(rows: [], binary: true)
            default: break
            }
            return .init(checkpoint: request.checkpoint, files: files, totalFiles: files.count, path: request.path, diff: diff,
                         context: request.path == nil || !honorsContext ? nil : context)
        }
    }

    private func window(_ diffs: HistoricalDiffs, path: String = "file.swift") -> AgentCheckpointDiffWindow {
        _ = NSApplication.shared
        let controller = AgentCheckpointDiffWindow(session: SessionId(), checkpoint: UUID().uuidString, path: path,
                                                   theme: AgentTheme(systemIsDark: false)) { diffs.reply($0) }
        controller.onReviewChange = { [weak controller] in controller?.reviewComments = $0 }
        return controller
    }

    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    private func button(_ controller: AgentCheckpointDiffWindow, _ titles: Set<String>) throws -> PillButton {
        let content = try XCTUnwrap(controller.window?.contentView)
        return try XCTUnwrap(descendants(content).compactMap { $0 as? PillButton }.first { titles.contains($0.title) })
    }

    private func rows(_ controller: AgentCheckpointDiffWindow) throws -> DiffRowsView {
        try XCTUnwrap(descendants(try XCTUnwrap(controller.window?.contentView)).compactMap { $0 as? DiffRowsView }.first)
    }

    /// More Context reads more of the checkpoint's own lines, up to the whole file; a runtime
    /// that predates it keeps the usual three and the control says why.
    func testMoreContextReadsTheCheckpointsOwnLinesUpToTheWholeFile() async throws {
        let diffs = HistoricalDiffs()
        let controller = window(diffs)
        defer { controller.close() }
        try await settle { controller.shownDocument != nil }
        XCTAssertEqual(controller.shownDocument?.rows.count, 8, "Three lines on each side of the change")
        XCTAssertEqual(diffs.requests.last?.context, nil, "The usual three lines need no new field")
        let more = try button(controller, ["More context"])
        XCTAssertFalse(more.isHidden)
        controller.showMoreContext()
        try await settle { controller.shownDocument?.rows.count == 41 }
        XCTAssertEqual(diffs.requests.last?.context, 25)
        XCTAssertEqual(controller.shownDocument?.rows.first?.text, " old 1", "Lines come from the checkpoint")
        controller.showMoreContext()
        try await settle { diffs.requests.last?.context == AgentCheckpointRequest.wholeFile && controller.shownDocument != nil }
        let whole = try button(controller, ["Whole file"])
        XCTAssertFalse(whole.isEnabled)

        let older = HistoricalDiffs()
        older.honorsContext = false
        let previous = window(older)
        defer { previous.close() }
        try await settle { previous.shownDocument != nil }
        previous.showMoreContext()
        try await settle { older.requests.count >= 3 && previous.shownDocument != nil && previous.context == 3 }
        let unsupported = try button(previous, ["More context"])
        XCTAssertFalse(unsupported.isEnabled)
        XCTAssertEqual(unsupported.toolTip, "This agent service can't show more context.")

        let tool = window(HistoricalDiffs())
        tool.expandsContext = false
        defer { tool.close() }
        try await settle { tool.shownDocument != nil }
        XCTAssertTrue(try button(tool, ["More context"]).isHidden, "A tool's own patch has no more lines")
    }

    /// Saved comments are marked on the side and lines they were made on, in unified and
    /// split views; choosing one in the picker shows its lines, loading context it needs.
    func testSavedCommentsAreMarkedOnTheirSideAndRevealedFromThePicker() async throws {
        let diffs = HistoricalDiffs()
        let controller = window(diffs)
        defer { controller.close() }
        let checkpoint = controller.checkpointID
        let early = AgentReviewComment(checkpoint: checkpoint, path: "file.swift", old: false, firstLine: 2, lastLine: 3, source: "old 2\nold 3", text: "Rename")
        let removed = AgentReviewComment(checkpoint: checkpoint, path: "file.swift", old: true, firstLine: 20, lastLine: 20, source: "old 20", text: "Why?")
        let deleted = AgentReviewComment(checkpoint: checkpoint, path: "gone.swift", old: true, firstLine: 2, lastLine: 3, source: "gone 2", text: "Keep")
        controller.reviewComments = [early, removed, deleted]
        try await settle { controller.shownDocument != nil }
        let view = try rows(controller)
        let deletion = try XCTUnwrap(controller.shownDocument?.rows.firstIndex { $0.kind == .deletion })
        XCTAssertEqual(Array(view.markedOld), [deletion], "Only the old side of line 20 is marked")
        XCTAssertTrue(view.markedNew.isEmpty, "Lines 2–3 aren't in this preview")

        controller.showComments()
        controller.commentPicker?.onSelect?(early.id)
        try await settle { view.reviewSelection != nil }
        XCTAssertEqual(diffs.requests.last?.context, AgentCheckpointRequest.wholeFile, "Loaded the lines the comment is on")
        let document = try XCTUnwrap(controller.shownDocument)
        let selected = try XCTUnwrap(view.reviewSelection?.lines(in: document))
        XCTAssertEqual([selected.first, selected.last], [2, 3])
        XCTAssertEqual(view.reviewSelection?.old, false)
        XCTAssertEqual(view.markedNew.count, 2)
        XCTAssertEqual(try button(controller, ["Edit comment", "Add comment"]).title, "Edit comment")
        controller.commentPicker?.close()

        view.split = true
        controller.reveal(removed)
        try await settle { view.reviewSelection?.old == true }
        XCTAssertEqual(view.reviewSelection?.lines(in: document).map { [$0.first, $0.last] }, [20, 20])

        controller.reveal(deleted)
        try await settle { controller.shownDocument?.rows.first { $0.kind != .hunk }?.text == "-gone 1" && view.reviewSelection != nil }
        let gone = try XCTUnwrap(controller.shownDocument)
        XCTAssertEqual(view.reviewSelection?.lines(in: gone).map { [$0.first, $0.last] }, [2, 3])
        XCTAssertEqual(view.markedOld.count, 2)
    }

    /// A comment a truncated diff can't show says so; a binary file shows no lines.
    func testTruncatedAndBinaryDiffsSayWhatTheyCantShow() async throws {
        let diffs = HistoricalDiffs()
        let controller = window(diffs, path: "big.swift")
        defer { controller.close() }
        try await settle { controller.shownDocument != nil }
        let late = AgentReviewComment(checkpoint: controller.checkpointID, path: "big.swift", old: false, firstLine: 30, lastLine: 30,
                                      source: "big 30", text: "Here")
        controller.reviewComments = [late]
        controller.reveal(late)
        let content = try XCTUnwrap(controller.window?.contentView)
        let note = { self.descendants(content).compactMap { $0 as? NSTextField }.first { !$0.isHidden && $0.stringValue.hasPrefix("This comment's lines") } }
        try await settle { note() != nil }
        XCTAssertEqual(note()?.stringValue, "This comment's lines aren't in the diff preview, which is truncated.")

        let binary = window(diffs, path: "logo.png")
        defer { binary.close() }
        let binaryContent = try XCTUnwrap(binary.window?.contentView)
        try await settle { self.descendants(binaryContent).compactMap { $0 as? NSTextField }.contains { !$0.isHidden && $0.stringValue == "Binary file changed." } }
        XCTAssertNil(binary.shownDocument)
    }
}
