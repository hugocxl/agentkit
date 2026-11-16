import AppKit
@MainActor
public enum NativeStyle {
    /// The side panel card: 6% foreground over the background in dark
    /// themes, mostly white in light ones.
    public static func panel(_ theme: AgentTheme) -> NSColor {
        if theme.glassEnabled { return theme.bg }
        if theme.palette.isLight {
            return theme.bg.blended(withFraction: 0.7, of: .white) ?? theme.bg
        }
        return theme.palette.fg.blended(over: theme.palette.bg, amount: 0.06).nsColor
    }

    /// The width of one character cell and the height of a line in `font`.
    public static func cell(_ font: NSFont) -> NSSize {
        let width = ("M" as NSString).size(withAttributes: [.font: font]).width
        let height = (font.ascender - font.descender + font.leading).rounded(.up) + 3
        return NSSize(width: max(width, 1), height: max(height, 1))
    }
}
