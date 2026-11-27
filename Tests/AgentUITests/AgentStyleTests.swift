import AgentCore
import AppKit
import XCTest
@testable import AgentUI

@MainActor
final class AgentStyleTests: XCTestCase {
    override func tearDown() {
        AgentTheme(systemIsDark: true).setStyle(AgentStyle())
        super.tearDown()
    }

    func testDefaultStyleKeepsTheDesktopGeometryAndFonts() {
        AgentTheme(systemIsDark: true).setStyle(AgentStyle())
        XCTAssertEqual(Metrics.gutter, 8)
        XCTAssertEqual(Metrics.cardRadius, 10)
        XCTAssertEqual(Metrics.controlHeight, 24)
        XCTAssertEqual(GlassView.Style.agentComposer.cornerRadius, 20)
        XCTAssertEqual(AppFont.body.pointSize, 13)
        XCTAssertEqual(AppFont.body.familyName, NSFont.systemFont(ofSize: 13).familyName)
        XCTAssertEqual(AgentFont.system(14).pointSize, 14)
    }

    func testStyleSetsGeometryRadiiAndChromeFontSizes() {
        var style = AgentStyle()
        style.spacing.gutter = 12
        style.radii = .uniform(0)
        style.controls.height = 30
        style.typography.fontSize = 15
        AgentTheme(systemIsDark: true).setStyle(style)
        XCTAssertEqual(Metrics.gutter, 12)
        XCTAssertEqual(Metrics.cardRadius, 0)
        XCTAssertEqual(AgentMessageShape.radius, 0)
        XCTAssertEqual(GlassView.Style.agentPanel.cornerRadius, 0)
        XCTAssertEqual(AgentPanelMetrics.rowRadius, 0, "A row's radius never goes negative")
        XCTAssertEqual(Metrics.controlHeight, 30)
        XCTAssertEqual(AppFont.body.pointSize, 15)
        XCTAssertEqual(AppFont.footnote.pointSize, 12.5, "Smaller sizes keep their proportion on a half-point grid")
    }

    func testFontFamiliesApplyAndMissingFamiliesFallBack() {
        var style = AgentStyle()
        style.typography.fontFamily = "Helvetica Neue"
        style.typography.monospacedFontFamily = "Menlo"
        AgentTheme(systemIsDark: true).setStyle(style)
        XCTAssertEqual(AppFont.body.familyName, "Helvetica Neue")
        XCTAssertEqual(AgentFont.system(14).familyName, "Helvetica Neue")
        XCTAssertEqual(AppFont.mono(12).familyName, "Menlo")
        XCTAssertEqual(AgentInlineCodeLayout.font(size: 12).familyName, "Menlo")
        let bold = AppFont.system(13, weight: .bold)
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.bold), "The nearest face to the weight is chosen")

        style.typography.fontFamily = "No Such Family 7d1e"
        AgentTheme(systemIsDark: true).setStyle(style)
        XCTAssertEqual(AppFont.body.familyName, NSFont.systemFont(ofSize: 13).familyName)
    }

    func testConversationFontSizeRendersMarkdownAgain() throws {
        _ = NSApplication.shared
        let theme = AgentTheme(systemIsDark: true)
        let cache = AgentMarkdownRenderCache()
        let blocks = AgentMarkdown.blocks("Body")
        let normal = AgentMarkdown.render(blocks, theme: theme, cache: cache)
        XCTAssertEqual(try XCTUnwrap(normal.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).pointSize, 14)
        var style = AgentStyle()
        style.typography.conversationFontSize = 16
        style.typography.fontFamily = "Helvetica Neue"
        theme.setStyle(style)
        let restyled = AgentMarkdown.render(blocks, theme: theme, cache: cache)
        let font = try XCTUnwrap(restyled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 16)
        XCTAssertEqual(font.familyName, "Helvetica Neue", "A cached render is not reused after the style changes")
    }

    func testColorOverridesRecolorTheThemeAndDeriveTints() {
        let theme = AgentTheme(systemIsDark: true)
        let original = theme.palette
        let accent = ChromeColor(hex: 0xFF_FF_FF)
        let background = ChromeColor(hex: 0x10_20_30)
        theme.setStyle(AgentStyle(colors: .init(dark: ChromePaletteOverrides(background: background, accent: accent))))
        XCTAssertEqual(theme.palette.accent, accent)
        XCTAssertEqual(theme.palette.accentSoft, accent.withAlpha(0.1))
        XCTAssertEqual(theme.palette.accentForeground, ChromeColor(red: 0, green: 0, blue: 0), "Text on a light accent turns dark")
        XCTAssertEqual(theme.palette.bg, background)
        XCTAssertEqual(theme.palette.border, original.fg.blended(over: background, amount: 0.12))
        XCTAssertEqual(theme.palette.fg, original.fg)
        XCTAssertEqual(theme.palette.danger, original.danger)

        theme.setStyle(AgentStyle(colors: .init(light: ChromePaletteOverrides(accent: accent))))
        XCTAssertEqual(theme.palette, original, "A dark theme ignores light overrides")
        theme.setStyle(AgentStyle())
        XCTAssertEqual(theme.palette, original)
    }

    func testStyleChangeNotifiesThemedViews() {
        _ = NSApplication.shared
        let theme = AgentTheme(systemIsDark: true)
        let view = ThemedView()
        view.theme = theme
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        var changes = 0
        view.onColorsChange = { changes += 1 }
        let notified = expectation(forNotification: .agentTextScaleDidChange, object: nil)
        let revision = AgentTextScale.revision
        theme.setStyle(AgentStyle(colors: .init(ChromePaletteOverrides(accent: ChromeColor(hex: 0x00_FF_00)))))
        var style = theme.style
        style.spacing.message = 40
        theme.setStyle(style)
        wait(for: [notified], timeout: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertGreaterThan(AgentTextScale.revision, revision)
        XCTAssertEqual(changes, 1, "The accent override reached the view once")
        XCTAssertEqual(AgentTranscriptLayout().spacing, 40)
    }
}
