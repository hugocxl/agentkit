import AgentCore
import AppKit
import XCTest
@testable import AgentUI

@MainActor
final class AgentResponsePerformanceTests: XCTestCase {
    private let source = """
    A completed paragraph with **formatting**.

    ```swift
    let complete = true
    let longLine = "A deliberately long line that should wrap in a narrow response column and retain its own native text selection."
    ```

    | Name | State |
    | --- | --- |
    | Completed table | Ready |

    The streaming tail
    """

    func testTrailingStreamUpdatesOnlyOneSectionAndReusesCompletedMeasurements() throws {
        _ = NSApplication.shared
        let response = AgentResponseView(frame: .zero)
        let theme = AgentTheme(systemIsDark: true)
        response.setContent(source, theme: theme)
        let height = response.height(for: 640)
        response.frame = NSRect(x: 0, y: 0, width: 640, height: height)
        response.layoutSubtreeIfNeeded()
        let code = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseCode }.first)
        code.text.setSelectedRange(NSRange(location: 0, length: 3))
        let initialUpdates = response.sectionUpdateCount
        let initialMeasurements = response.sectionMeasurementCount
        let initialLineScans = code.longestLineScanCount
        XCTAssertEqual(initialUpdates, 4, "The fixture has prose, code, table, and trailing prose")

        for _ in 0..<50 { _ = response.height(for: 640) }
        XCTAssertEqual(response.sectionMeasurementCount, initialMeasurements)
        for token in 1...25 {
            response.setContent(source + String(repeating: " token", count: token), theme: theme)
            _ = response.height(for: 640)
        }
        XCTAssertEqual(response.sectionUpdateCount - initialUpdates, 25,
                       "Completed prose, code and table must not rebuild attributed text")
        XCTAssertEqual(response.sectionMeasurementCount - initialMeasurements, 25,
                       "Only the growing tail should run TextKit measurement")
        XCTAssertEqual(code.longestLineScanCount, initialLineScans)
        XCTAssertEqual(code.text.selectedRange(), NSRange(location: 0, length: 3))
        XCTAssertTrue(code === response.subviews.compactMap { $0 as? AgentResponseCode }.first)

        let beforeResize = response.sectionMeasurementCount
        _ = response.height(for: 360)
        XCTAssertEqual(response.sectionMeasurementCount - beforeResize, 4)
        XCTAssertEqual(code.longestLineScanCount, initialLineScans,
                       "A width change must not rescan unchanged source lines")
        for _ in 0..<50 { _ = response.height(for: 360) }
        XCTAssertEqual(response.sectionMeasurementCount - beforeResize, 4)
    }

    func testWrapStateSurvivesEvictionAndRestoresSilently() throws {
        _ = NSApplication.shared
        let theme = AgentTheme(systemIsDark: true)
        let original = AgentResponseView(frame: .zero)
        original.setContent(source, theme: theme)
        let code = try XCTUnwrap(original.subviews.compactMap { $0 as? AgentResponseCode }.first)
        XCTAssertTrue(code.wrapped, "Conversation defaults code blocks to wrapped text")
        code.setWrapped(false)
        let unwrappedHeight = original.height(for: 280)
        var userChanges = 0
        original.onHeightChanged = { userChanges += 1 }
        code.wrap.perform()
        XCTAssertEqual(userChanges, 1)
        XCTAssertTrue(code.wrapped)
        let metadata = original.wrappedCodeSections
        XCTAssertEqual(metadata, [1], "Indices address all response sections, not just code sections")

        let recreated = AgentResponseView(frame: .zero)
        recreated.setContent(source, theme: theme)
        var restoreCallbacks = 0
        recreated.onHeightChanged = { restoreCallbacks += 1 }
        recreated.wrappedCodeSections = metadata
        let wrappedHeight = recreated.height(for: 280)
        XCTAssertEqual(restoreCallbacks, 0, "Restoration must not recursively reflow the virtualizer")
        XCTAssertEqual(recreated.wrappedCodeSections, metadata)
        XCTAssertGreaterThan(wrappedHeight, unwrappedHeight)

        let measured = recreated.sectionMeasurementCount
        recreated.wrappedCodeSections = metadata
        _ = recreated.height(for: 280)
        XCTAssertEqual(recreated.sectionMeasurementCount, measured, "Idempotent restore must not invalidate caches")
        recreated.wrappedCodeSections = []
        _ = recreated.height(for: 280)
        XCTAssertEqual(recreated.sectionMeasurementCount, measured + 1, "Only the changed code section is remeasured")
        XCTAssertEqual(restoreCallbacks, 0)
    }

    func testThemeInvalidatesSectionCachesButDoesNotRescanCodeWidth() throws {
        _ = NSApplication.shared
        let response = AgentResponseView(frame: .zero)
        let catalog = ThemeCatalog.load(customDirectory: nil)
        let dark = AgentTheme(catalog: catalog, systemIsDark: true)
        let light = AgentTheme(catalog: catalog, systemIsDark: false)
        XCTAssertNotEqual(dark.palette, light.palette)
        response.setContent(source, theme: dark)
        _ = response.height(for: 640)
        let code = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseCode }.first)
        let updates = response.sectionUpdateCount
        let measurements = response.sectionMeasurementCount
        let lineScans = code.longestLineScanCount
        response.setContent(source, theme: light)
        _ = response.height(for: 640)
        XCTAssertEqual(response.sectionUpdateCount, updates + 4)
        XCTAssertEqual(response.sectionMeasurementCount, measurements + 4)
        XCTAssertEqual(code.longestLineScanCount, lineScans)
        let afterTheme = response.sectionMeasurementCount
        _ = response.height(for: 640)
        XCTAssertEqual(response.sectionMeasurementCount, afterTheme)
    }

    /// A long answer of plain paragraphs is one prose section; streaming its last
    /// paragraph must render that paragraph alone and leave the earlier text in place.
    func testLongProseStreamingRendersOnlyTheTail() throws {
        _ = NSApplication.shared
        let theme = AgentTheme(systemIsDark: true)
        let paragraphs = (1...200).map { "Paragraph \($0) with **bold** text and a `code` span that wraps across a line or two." }
        let response = AgentResponseView(frame: .zero)
        response.isStreaming = true
        response.setContent(paragraphs.joined(separator: "\n\n"), theme: theme)
        _ = response.height(for: 640)
        let prose = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseProse }.first)
        XCTAssertEqual(response.subviews.compactMap { $0 as? AgentResponseProse }.count, 1)
        let before = prose.renderCache.renderedBlocks
        let start = Date()
        for token in 1...25 {
            response.setContent(paragraphs.joined(separator: "\n\n") + String(repeating: " more", count: token), theme: theme)
            _ = response.height(for: 640)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(prose.renderCache.renderedBlocks - before, 25, "Each update renders only the growing paragraph")
        // About 0.3 s on an M1 in a debug build; a full re-render of every paragraph took 2 s.
        XCTAssertLessThan(elapsed, 1, "25 updates of a 200-paragraph answer took \(elapsed) s")
        let streamed = prose.text.attributedString()
        let fresh = AgentResponseView(frame: .zero)
        fresh.isStreaming = true
        fresh.setContent(paragraphs.joined(separator: "\n\n") + String(repeating: " more", count: 25), theme: theme)
        let reference = try XCTUnwrap(fresh.subviews.compactMap { $0 as? AgentResponseProse }.first).text.attributedString()
        XCTAssertTrue(streamed.isEqual(to: reference), "Reused blocks must render exactly as a fresh render")
    }

    func testOnlyTheChangedParagraphsAreReplaced() {
        let old = NSAttributedString(string: "First\nSecond\nThird")
        XCTAssertEqual(AgentRichTextView.unchangedParagraphs(old, NSAttributedString(string: "First\nSecond\nThird and more")), 13)
        XCTAssertEqual(AgentRichTextView.unchangedParagraphs(old, NSAttributedString(string: "First\nSecond\nThird\nFourth")), 13)
        XCTAssertEqual(AgentRichTextView.unchangedParagraphs(old, NSAttributedString(string: "Other")), 0)
        let restyled = NSMutableAttributedString(string: "First\nSecond\nThird more")
        restyled.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 2))
        XCTAssertEqual(AgentRichTextView.unchangedParagraphs(old, restyled), 0, "Changed attributes in the prefix replace everything")
    }

    func testTextScaleSizesConversationText() throws {
        _ = NSApplication.shared
        defer { AgentTextScale.set(1) }
        let theme = AgentTheme(systemIsDark: true)
        let normal = AgentMarkdown.render(AgentMarkdown.blocks("Body"), theme: theme)
        XCTAssertTrue(AgentTextScale.step(larger: true))
        let larger = AgentMarkdown.render(AgentMarkdown.blocks("Body"), theme: theme)
        let normalSize = try XCTUnwrap(normal.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).pointSize
        let largerSize = try XCTUnwrap(larger.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).pointSize
        XCTAssertGreaterThan(largerSize, normalSize)
        AgentTextScale.set(AgentTextScale.steps.last ?? 1)
        XCTAssertFalse(AgentTextScale.step(larger: true), "The scale stops at its largest step")
    }

    /// T7's workload: a long answer of headings, formatted paragraphs with reference links,
    /// lists, code and tables, whose reference definitions arrive last, streamed in 120
    /// even chunks. Each update is timed as a full parse (the parser before checkpoints),
    /// as the resumed parse the streaming view runs, and as the view's own setContent,
    /// layout and drawing of the visible end. The figures print with the workload.
    func testStreamedResponseParsingCostsLessThanLayoutAndDrawing() throws {
        _ = NSApplication.shared
        let theme = AgentTheme(systemIsDark: true)
        let source = Self.longStreamedResponse()
        let chunks = 120
        let response = AgentResponseView(frame: .zero)
        response.isStreaming = true
        var full: [Double] = [], resumed: [Double] = [], set: [Double] = [], layout: [Double] = [], draw: [Double] = []
        var checkpoint: AgentResponseParser.Checkpoint?
        let clock = ContinuousClock()
        func ms(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }
        func parse(_ prefix: String, resuming: Bool) {
            let held = AgentStreamingCompletion.holdingBackAmbiguousTail(prefix)
            let parsed = resuming ? AgentResponseParser.parse(held, resuming: &checkpoint) : AgentResponseParser.parse(held)
            let blocks = AgentStreamingCompletion.completingLastBlock(parsed)
            _ = AgentMarkdownReferences.collect(blocks, parseRawHTML: true)
            _ = AgentMarkdownFootnotes.prepare(blocks, parseRawHTML: true)
        }
        for chunk in 1...chunks {
            let end = source.index(source.startIndex, offsetBy: source.count * chunk / chunks)
            let prefix = String(source[..<end])
            full.append(ms(clock.measure { parse(prefix, resuming: false) }))
            resumed.append(ms(clock.measure { parse(prefix, resuming: true) }))
            set.append(ms(clock.measure { response.setContent(prefix, theme: theme) }))
            var height: CGFloat = 0
            layout.append(ms(clock.measure {
                height = response.height(for: 640)
                response.frame = NSRect(x: 0, y: 0, width: 640, height: height)
                response.layoutSubtreeIfNeeded()
            }))
            let visible = NSRect(x: 0, y: max(0, height - 900), width: 640, height: min(900, height))
            draw.append(ms(clock.measure {
                guard let bitmap = response.bitmapImageRepForCachingDisplay(in: visible) else { return }
                response.cacheDisplay(in: visible, to: bitmap)
            }))
        }
        func median(_ values: [Double]) -> Double { values.suffix(30).sorted()[15] }
        func summary(_ values: [Double]) -> String {
            String(format: "total %.0f ms, last-30 median %.2f ms, max %.2f ms", values.reduce(0, +), median(values), values.max() ?? 0)
        }
        print("T7 workload: \(source.utf8.count) bytes, \(source.split(separator: "\n", omittingEmptySubsequences: false).count) lines, \(chunks) streamed updates")
        print("T7 full parse:    " + summary(full))
        print("T7 resumed parse: " + summary(resumed))
        print("T7 setContent:    " + summary(set))
        print("T7 layout:        " + summary(layout))
        print("T7 draw:          " + summary(draw))
        XCTAssertLessThan(median(resumed), median(full) / 2, "Resuming must skip the finished blocks")
        XCTAssertLessThan(median(resumed), median(layout) + median(draw), "Parsing outweighs rendering the update")
        // The streamed result matches parsing the finished answer whole.
        response.isStreaming = false
        response.setContent(source, theme: theme)
        let fresh = AgentResponseView(frame: .zero)
        fresh.setContent(source, theme: theme)
        for view in [response, fresh] {
            view.frame = NSRect(x: 0, y: 0, width: 640, height: view.height(for: 640))
            view.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(response.textViews.count, fresh.textViews.count)
        let tables = Set(response.sectionViews.compactMap { ($0 as? AgentResponseTable)?.text }.map(ObjectIdentifier.init))
        for (streamed, whole) in zip(response.textViews, fresh.textViews) {
            // Table cells carry paragraph styles from their measured column widths.
            if tables.contains(ObjectIdentifier(streamed)) {
                XCTAssertEqual(streamed.string, whole.string)
            } else {
                XCTAssertTrue(streamed.attributedString().isEqual(to: whole.attributedString()),
                              "Streamed text differs: \(streamed.string.prefix(80))")
            }
        }
    }

    /// The streaming parser resumes from its last block boundary. Every streamed prefix
    /// must parse to exactly the blocks a full parse gives, including reference definitions
    /// that arrive after the links using them, lists that turn loose, fences, `<details>`,
    /// unclosed display math and HTML that a later line could still close.
    func testResumedParsingMatchesFullParsingForEveryStreamedPrefix() throws {
        let tricky = """
        Intro with a [late][r1] link and [another][R2].

        - one
        - two

        - three, after a blank, makes the list loose

        Paragraph between lists.

        $$
        x = 1

        Text after an unclosed math opener.

        <details>
        <summary>More</summary>

        Inside details

        </details>

        | a | b |
        | - | - |
        | 1 | 2 |

        Setext
        ===

        1. first

           continued, indented

        2. second

        <pre>
        code

        </pre>

        ~~~
        tilde

        ```
        ~~~

        [^1]: A footnote
            continued

            more

        Back to text.[^1]

        [r1]: https://example.com/late
        [R2]: <https://example.com/second> "Title"

        """
        for rawHTML in [true, false] {
            var checkpoint: AgentResponseParser.Checkpoint?
            var prefix = ""
            for character in tricky {
                prefix.append(character)
                let held = AgentStreamingCompletion.holdingBackAmbiguousTail(prefix)
                let resumed = AgentResponseParser.parse(held, parseRawHTML: rawHTML, resuming: &checkpoint)
                let full = AgentResponseParser.parse(held, parseRawHTML: rawHTML)
                guard resumed == full else {
                    return XCTFail("Resumed parse differs at \(prefix.count) characters (raw HTML \(rawHTML)): \(held.suffix(60).debugDescription)")
                }
            }
            XCTAssertEqual(AgentMarkdownReferences.collect(AgentResponseParser.parse(tricky, parseRawHTML: rawHTML, resuming: &checkpoint), parseRawHTML: rawHTML),
                           AgentMarkdownReferences.collect(AgentResponseParser.parse(tricky, parseRawHTML: rawHTML), parseRawHTML: rawHTML))
        }
        let long = Self.longStreamedResponse()
        var checkpoint: AgentResponseParser.Checkpoint?
        var offset = 0
        let characters = Array(long)
        while offset < characters.count {
            offset = min(characters.count, offset + 97)
            let held = AgentStreamingCompletion.holdingBackAmbiguousTail(String(characters[..<offset]))
            XCTAssertEqual(AgentResponseParser.parse(held, resuming: &checkpoint), AgentResponseParser.parse(held))
        }
        XCTAssertGreaterThan(try XCTUnwrap(checkpoint).reusedLines, 1400, "The finished blocks are reused")
        // An edit before the boundary, not an append, parses everything again.
        let edited = "Changed start.\n\n" + long
        XCTAssertEqual(AgentResponseParser.parse(edited, resuming: &checkpoint), AgentResponseParser.parse(edited))
    }

    /// About 64 KB of mixed Markdown whose link reference definitions come at the end.
    static func longStreamedResponse() -> String {
        var parts: [String] = []
        for section in 1...120 {
            parts.append("## Section \(section)")
            parts.append("This paragraph explains **step \(section)** with _emphasis_, `inline code`, and a [reference link][ref\(section % 12)] that resolves only once the definitions at the end arrive.")
            parts.append((1...4).map { "- Item \($0) of section \(section), with a `token` and a [link](https://example.com/\(section)/\($0))" }.joined(separator: "\n"))
            if section % 5 == 0 {
                parts.append("```swift\n" + (1...8).map { "let value\($0) = compute(\(section), \($0)) // line \($0)" }.joined(separator: "\n") + "\n```")
            }
            if section % 7 == 0 {
                parts.append("| Name | Value | Note |\n| --- | ---: | --- |\n" + (1...5).map { "| row \($0) | \($0 * section) | **ok** |" }.joined(separator: "\n"))
            }
        }
        parts.append((0..<12).map { "[ref\($0)]: https://example.com/reference/\($0)" }.joined(separator: "\n"))
        return parts.joined(separator: "\n\n")
    }
}
