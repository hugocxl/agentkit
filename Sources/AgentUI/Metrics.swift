import AgentCore
import AppKit

/// The desktop style's geometry: by default one
/// 8pt gutter, 10pt card radius, 1pt border, 36pt headers and 8pt control
/// gaps. Views use these instead of literal numbers so the chrome stays one
/// system, and `AgentStyle` can change them together.
public enum Metrics {
    private static var style: AgentStyle { AgentStyle.current }

    /// Window inset, gaps between cards, sidebar and panel padding.
    public static var gutter: CGFloat { style.spacing.gutter }
    public static var cardRadius: CGFloat { style.radii.card }
    /// Glass cards in the sidebars: the selected tab card, the footer card
    /// and the usage panel's provider cards.
    public static var glassCardRadius: CGFloat { style.radii.card }
    public static var border: CGFloat { style.controls.borderWidth }
    public static var headerHeight: CGFloat { style.controls.headerHeight }
    public static var controlGap: CGFloat { style.spacing.controlGap }
    /// Header and toolbar glyphs.
    public static let glyph: CGFloat = 16

    public static var radiusSmall: CGFloat { style.radii.small }
    public static var radiusMedium: CGFloat { style.radii.medium }
    public static var radiusLarge: CGFloat { style.radii.large }

    /// Standard control height: buttons, fields, pop-ups, segmented pills.
    public static var controlHeight: CGFloat { style.controls.height }
    /// Width of text fields and pop-ups in settings rows.
    public static let controlWidth: CGFloat = 210
    public static let sliderWidth: CGFloat = 220

    public static let sidebarExpandedWidth: CGFloat = 270
    public static let sidebarMinimumWidth: CGFloat = 180
    public static let sidebarMaximumWidth: CGFloat = 480

    /// A keycap's side, as in the command palette.
    public static let keycap: CGFloat = 20
}

/// The app's fonts: SF for the chrome, SF Mono where text lines up, or the
/// families of `AgentStyle.current`. Sizes are given at the default 13pt
/// body and scale with the style's font size.
public enum AppFont {
    /// Card and pane headers: 13pt semibold.
    public static var header: NSFont { system(13, weight: .semibold) }
    public static var body: NSFont { system(13) }
    public static var bodyMedium: NSFont { system(13, weight: .medium) }
    public static var small: NSFont { system(12) }
    public static var footnote: NSFont { system(11) }
    public static var footnoteMedium: NSFont { system(11, weight: .medium) }
    public static var caption: NSFont { system(10) }
    public static var micro: NSFont { system(8, weight: .bold) }
    public static var title: NSFont { system(17, weight: .semibold) }

    public static func system(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        AgentFontFactory.text(scaled(size), weight: weight)
    }

    /// Text whose digits keep one width, for counters and times that tick.
    public static func digits(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        AgentFontFactory.text(scaled(size), weight: weight, monospacedDigits: true)
    }

    public static func mono(_ size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSFont {
        AgentFontFactory.mono(scaled(size), weight: weight)
    }

    /// `size` at the style's chrome scale, on a half-point grid.
    static func scaled(_ size: CGFloat) -> CGFloat {
        let scale = AgentStyle.current.typography.chromeScale
        return scale == 1 ? size : (size * scale * 2).rounded() / 2
    }
}
