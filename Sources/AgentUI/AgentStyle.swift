import AgentCore
import AppKit

/// How AgentKit's views look beyond the theme's colors: typography, spacing,
/// corner radii, control sizes and color overrides, so an embedded
/// conversation can match the app around it.
///
/// Apply one with `AgentTheme.setStyle(_:)`. Typography, spacing and radii
/// are app-wide: the last style set wins, so give every theme the same one.
/// Color overrides belong to the theme they are set on. Set the style before
/// building views; conversation text, its spacing and theme colors also
/// update live, while chrome fonts and radii apply to views built afterwards.
///
/// ```swift
/// var style = AgentStyle()
/// style.typography.fontFamily = "Inter"
/// style.typography.conversationFontSize = 15
/// style.radii.composer = 12
/// style.colors = .init(ChromePaletteOverrides(accent: ChromeColor(hex: 0x6366F1)))
/// theme.setStyle(style)
/// ```
public struct AgentStyle: Equatable, Sendable {
    public var typography: Typography
    public var spacing: Spacing
    public var radii: Radii
    public var controls: Controls
    public var colors: Colors

    public init(typography: Typography = Typography(), spacing: Spacing = Spacing(), radii: Radii = Radii(),
                controls: Controls = Controls(), colors: Colors = Colors()) {
        self.typography = typography
        self.spacing = spacing
        self.radii = radii
        self.controls = controls
        self.colors = colors
    }

    /// Font families and sizes. Every size in the chrome scales with
    /// `fontSize`, and every size in a conversation with `conversationFontSize`,
    /// so headings, captions and code keep their proportions.
    public struct Typography: Equatable, Sendable {
        /// The text family, such as `"Inter"`; nil uses the system font.
        /// A family that is not installed falls back to the system font.
        public var fontFamily: String?
        /// The design of the system font when `fontFamily` is nil.
        public var systemDesign: SystemDesign
        /// The code and terminal family, such as `"JetBrains Mono"`; nil uses SF Mono.
        public var monospacedFontFamily: String?
        /// Body text in the chrome: buttons, menus, panels and the composer. Default 13.
        public var fontSize: CGFloat
        /// Body text of conversation messages. Default 14.
        public var conversationFontSize: CGFloat

        public init(fontFamily: String? = nil, systemDesign: SystemDesign = .default, monospacedFontFamily: String? = nil,
                    fontSize: CGFloat = 13, conversationFontSize: CGFloat = 14) {
            self.fontFamily = fontFamily
            self.systemDesign = systemDesign
            self.monospacedFontFamily = monospacedFontFamily
            self.fontSize = fontSize
            self.conversationFontSize = conversationFontSize
        }

        public enum SystemDesign: String, Sendable, CaseIterable {
            case `default`, rounded, serif
        }

        /// How much chrome sizes grow over the default 13pt.
        var chromeScale: CGFloat { max(fontSize, 1) / 13 }
        /// How much conversation sizes grow over the default 14pt.
        var conversationScale: CGFloat { max(conversationFontSize, 1) / 14 }
    }

    /// Gaps and widths, in points.
    public struct Spacing: Equatable, Sendable {
        /// Window insets, gaps between cards, sidebar and panel padding. Default 8.
        public var gutter: CGFloat
        /// Between neighboring controls. Default 8.
        public var controlGap: CGFloat
        /// Between one turn of the conversation and the next. Default 26.
        public var message: CGFloat
        /// Between paragraphs, lists and other blocks of a reply. Default 10.4.
        public var paragraph: CGFloat
        /// The widest a conversation column grows, centered in wider panes. Default 896.
        public var readableWidth: CGFloat

        public init(gutter: CGFloat = 8, controlGap: CGFloat = 8, message: CGFloat = 26, paragraph: CGFloat = 10.4, readableWidth: CGFloat = 896) {
            self.gutter = gutter
            self.controlGap = controlGap
            self.message = message
            self.paragraph = paragraph
            self.readableWidth = readableWidth
        }
    }

    /// Corner radii, in points.
    public struct Radii: Equatable, Sendable {
        /// Pills, badges and inline code. Default 4.
        public var small: CGFloat
        /// Buttons, fields and small boxes. Default 6.
        public var medium: CGFloat
        /// Code blocks, tool output and cards in a conversation. Default 8.
        public var large: CGFloat
        /// Pane cards and attachments. Default 10.
        public var card: CGFloat
        /// The user's message bubbles. Default 8.
        public var message: CGFloat
        /// The composer. Default 20.
        public var composer: CGFloat
        /// Panels above the composer: questions, the prompt queue and notices. Default 16.
        public var panel: CGFloat
        /// Suggestions, tooltips and other popovers. Default 10.
        public var popover: CGFloat

        public init(small: CGFloat = 4, medium: CGFloat = 6, large: CGFloat = 8, card: CGFloat = 10, message: CGFloat = 8,
                    composer: CGFloat = 20, panel: CGFloat = 16, popover: CGFloat = 10) {
            self.small = small
            self.medium = medium
            self.large = large
            self.card = card
            self.message = message
            self.composer = composer
            self.panel = panel
            self.popover = popover
        }

        /// The same corners everywhere, such as 0 for a square look.
        public static func uniform(_ radius: CGFloat) -> Radii {
            Radii(small: radius, medium: radius, large: radius, card: radius, message: radius, composer: radius, panel: radius, popover: radius)
        }
    }

    /// Control and header sizes, in points.
    public struct Controls: Equatable, Sendable {
        /// Buttons, fields, pop-ups and segmented pills. Default 24.
        public var height: CGFloat
        /// Pane and card headers. Default 36.
        public var headerHeight: CGFloat
        /// Card and control borders. Default 1.
        public var borderWidth: CGFloat

        public init(height: CGFloat = 24, headerHeight: CGFloat = 36, borderWidth: CGFloat = 1) {
            self.height = height
            self.headerHeight = headerHeight
            self.borderWidth = borderWidth
        }
    }

    /// Colors replacing the theme's, chosen by whether the theme in use is light or dark.
    public struct Colors: Equatable, Sendable {
        public var light: ChromePaletteOverrides
        public var dark: ChromePaletteOverrides

        public init(light: ChromePaletteOverrides = ChromePaletteOverrides(), dark: ChromePaletteOverrides = ChromePaletteOverrides()) {
            self.light = light
            self.dark = dark
        }

        /// The same overrides for light and dark themes, such as a brand accent.
        public init(_ both: ChromePaletteOverrides) {
            self.init(light: both, dark: both)
        }

        /// `palette` with the overrides for its lightness applied.
        public func apply(to palette: ChromePalette) -> ChromePalette {
            palette.applying(palette.isLight ? light : dark)
        }
    }

    /// The style every view reads. Written on the main thread by
    /// `AgentTheme.setStyle(_:)`; renderers read it while they draw.
    public internal(set) nonisolated(unsafe) static var current = AgentStyle()
}

/// Builds fonts in the style's families, caching each so views can ask on every draw.
enum AgentFontFactory {
    private struct Key: Hashable {
        var family: String?
        var design: String
        var size: CGFloat
        var weight: CGFloat
        var monospaced: Bool
        var digits: Bool
    }

    nonisolated(unsafe) private static var cache: [Key: NSFont] = [:]
    private static let lock = NSLock()

    /// Proportional text in the style's family.
    static func text(_ size: CGFloat, weight: NSFont.Weight = .regular, monospacedDigits: Bool = false) -> NSFont {
        let typography = AgentStyle.current.typography
        let key = Key(family: typography.fontFamily, design: typography.systemDesign.rawValue, size: size, weight: weight.rawValue, monospaced: false, digits: monospacedDigits)
        return cached(key) {
            var font: NSFont
            if let family = typography.fontFamily, let custom = face(in: family, size: size, weight: weight) {
                font = custom
            } else {
                font = monospacedDigits ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
                if let design = typography.systemDesign.descriptorDesign,
                   let descriptor = font.fontDescriptor.withDesign(design), let designed = NSFont(descriptor: descriptor, size: size) {
                    font = designed
                }
            }
            return monospacedDigits && typography.fontFamily != nil ? withMonospacedDigits(font) : font
        }
    }

    /// Code in the style's monospaced family.
    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let family = AgentStyle.current.typography.monospacedFontFamily
        let key = Key(family: family, design: "", size: size, weight: weight.rawValue, monospaced: true, digits: false)
        return cached(key) {
            family.flatMap { face(in: $0, size: size, weight: weight) } ?? .monospacedSystemFont(ofSize: size, weight: weight)
        }
    }

    /// Whether code uses the system's SF Mono, whose named faces some renderers pick directly.
    static var usesSystemMono: Bool { AgentStyle.current.typography.monospacedFontFamily == nil }

    private static func cached(_ key: Key, _ make: () -> NSFont) -> NSFont {
        lock.lock()
        if let font = cache[key] { lock.unlock(); return font }
        lock.unlock()
        let font = make()
        lock.lock()
        if cache.count > 512 { cache.removeAll(keepingCapacity: true) }
        cache[key] = font
        lock.unlock()
        return font
    }

    /// The face of `family` nearest `weight`, or nil when the family is not installed.
    private static func face(in family: String, size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
        let faces = descriptor.matchingFontDescriptors(withMandatoryKeys: [.family])
        let upright = faces.filter { !$0.symbolicTraits.contains(.italic) }
        let candidates = upright.isEmpty ? faces : upright
        func faceWeight(_ face: NSFontDescriptor) -> CGFloat {
            let traits = face.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
            return (traits?[.weight] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
        }
        guard let best = candidates.min(by: { abs(faceWeight($0) - weight.rawValue) < abs(faceWeight($1) - weight.rawValue) }) else { return nil }
        // A variable font offers one face for every weight: ask it for the exact one.
        let weighted = best.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]])
        return NSFont(descriptor: weighted, size: size) ?? NSFont(descriptor: best, size: size)
    }

    private static func withMonospacedDigits(_ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}

extension AgentStyle.Typography.SystemDesign {
    var descriptorDesign: NSFontDescriptor.SystemDesign? {
        switch self {
        case .default: nil
        case .rounded: .rounded
        case .serif: .serif
        }
    }
}
