import AgentCore
import Foundation

/// Chromium's positive CSS layout values are stored in 1/64-pixel units.
/// Preserve those fractions between native sections instead of rounding each block.
enum AgentMarkdownLayout {
    static func units(_ value: CGFloat) -> CGFloat { floor(value * 64) / 64 }
    /// Between blocks of a reply: the style's paragraph spacing.
    static var blockGap: CGFloat { units(AgentStyle.current.spacing.paragraph) }
    /// Between items of a compact list, in proportion to the paragraph spacing.
    static var compactListGap: CGFloat { units(AgentStyle.current.spacing.paragraph * 5.6 / 10.4) }
}
