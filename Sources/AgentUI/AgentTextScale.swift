import AgentCore
import AppKit

extension Notification.Name {
    /// Posted when the agent text scale or the style changes, so open conversations render again.
    static let agentTextScaleDidChange = Notification.Name("TabAgentTextScaleDidChange")
}

/// The size of agent conversation text, changed by the font-size shortcuts while an
/// agent pane is focused. One scale for every agent pane, kept for the app's session.
/// Changed only on the main thread; renderers read it while they draw.
enum AgentTextScale {
    static let steps: [CGFloat] = [0.8, 0.9, 1, 1.1, 1.2, 1.35, 1.5, 1.7]
    /// The step the user chose.
    nonisolated(unsafe) private(set) static var chosenStep: CGFloat = 1
    /// Counts every change to the scale or the style, so a renderer can tell its output is stale.
    nonisolated(unsafe) private(set) static var revision = 0

    /// The chosen step at the style's conversation font size.
    static var factor: CGFloat { chosenStep * AgentStyle.current.typography.conversationScale }

    /// `base` points at the current scale, on a half-point grid.
    static func size(_ base: CGFloat) -> CGFloat {
        let factor = factor
        return factor == 1 ? base : (base * factor * 2).rounded() / 2
    }

    /// Steps the scale up or down; false at either end.
    @MainActor @discardableResult
    static func step(larger: Bool) -> Bool {
        let index = steps.firstIndex(of: chosenStep) ?? steps.firstIndex(of: 1) ?? 0
        let next = index + (larger ? 1 : -1)
        guard steps.indices.contains(next) else { return false }
        set(steps[next])
        return true
    }

    @MainActor
    static func set(_ value: CGFloat) {
        guard value != chosenStep else { return }
        chosenStep = value
        invalidate()
    }

    /// Renders open conversations again, after the scale or the style changed.
    @MainActor
    static func invalidate() {
        revision &+= 1
        NotificationCenter.default.post(name: .agentTextScaleDidChange, object: nil)
    }
}

/// Agent conversation fonts at the current text scale.
enum AgentFont {
    static func system(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        AgentFontFactory.text(AgentTextScale.size(size), weight: weight)
    }

    /// Text whose digits keep one width, such as ordered list markers.
    static func digits(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        AgentFontFactory.text(AgentTextScale.size(size), weight: weight, monospacedDigits: true)
    }

    static func mono(_ size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSFont {
        AgentFontFactory.mono(AgentTextScale.size(size), weight: weight)
    }
}

/// What each block of a message rendered to last time, so a streaming update renders
/// only the blocks that changed.
final class AgentMarkdownRenderCache {
    struct Context: Equatable {
        var palette: ChromePalette
        var scheme: ColorScheme
        var fileLinks: Bool
        var references: [String: String]
        var compact: Bool
        var lineBreaks: Bool
        var rawHTML: Bool
        var listIndents: [Int: CGFloat]
        var revision: Int
    }

    struct Key: Equatable {
        var block: AgentMarkdown.Block
        var first: Bool
        var previous: AgentMarkdown.Block?
    }

    struct Part {
        var key: Key
        /// Nil when the block can't be reused.
        var text: NSAttributedString?
    }

    var context: Context?
    var parts: [Part] = []
    /// Blocks rendered rather than reused, for tests.
    var renderedBlocks = 0
}
