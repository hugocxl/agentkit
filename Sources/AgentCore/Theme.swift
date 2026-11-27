import Foundation

/// A 24-bit color, written `#rrggbb` in JSON and theme files.
public struct RGBColor: Hashable, Codable, Sendable, CustomStringConvertible {
    /// `0xRRGGBB`.
    public let value: UInt32

    public init(_ value: UInt32) {
        self.value = value & 0xFF_FFFF
    }

    /// Parses `#rrggbb` or `rrggbb`.
    public init?(hex: String) {
        var text = Substring(hex.trimmingCharacters(in: .whitespaces))
        if text.hasPrefix("#") { text = text.dropFirst() }
        guard text.count == 6, text.allSatisfy(\.isHexDigit), let value = UInt32(text, radix: 16) else { return nil }
        self.init(value)
    }

    /// Parses a color as Ghostty's config does: hex, or a basic color name.
    public init?(terminalValue value: String) {
        if let color = RGBColor(hex: value) {
            self = color
            return
        }
        let names: [String: UInt32] = [
            "black": 0, "white": 0xFF_FFFF, "red": 0xFF_0000, "green": 0x00_FF00, "blue": 0x00_00FF,
            "yellow": 0xFF_FF00, "magenta": 0xFF_00FF, "cyan": 0x00_FFFF, "gray": 0xBE_BEBE, "grey": 0xBE_BEBE,
        ]
        guard let named = names[value.lowercased()] else { return nil }
        self.init(named)
    }

    public var red: Double { Double((value >> 16) & 0xFF) / 255 }
    public var green: Double { Double((value >> 8) & 0xFF) / 255 }
    public var blue: Double { Double(value & 0xFF) / 255 }

    /// `#rrggbb`.
    public var hex: String { "#" + String(format: "%06x", value) }
    public var description: String { hex }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let color = RGBColor(terminalValue: text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "expected #RRGGBB or a basic color name, not \(text)"
            )
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// A color that can follow the cell under it, as cursor and selection colors
/// can in Ghostty.
public enum CellColor: Hashable, Codable, Sendable, CustomStringConvertible {
    case rgb(RGBColor)
    case cellForeground
    case cellBackground

    public init?(_ value: String) {
        switch value {
        case "cell-foreground": self = .cellForeground
        case "cell-background": self = .cellBackground
        default:
            guard let color = RGBColor(terminalValue: value) else { return nil }
            self = .rgb(color)
        }
    }

    /// The color for a cell with these colors.
    public func resolve(foreground: RGBColor, background: RGBColor) -> RGBColor {
        switch self {
        case .rgb(let color): return color
        case .cellForeground: return foreground
        case .cellBackground: return background
        }
    }

    public var description: String {
        switch self {
        case .rgb(let color): return color.hex
        case .cellForeground: return "cell-foreground"
        case .cellBackground: return "cell-background"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let color = CellColor(text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "expected #RRGGBB, cell-foreground or cell-background, not \(text)"
            )
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// The colors of a Ghostty theme file (`key = value` lines).
public struct ColorScheme: Equatable, Sendable {
    public var background: RGBColor?
    public var foreground: RGBColor?
    public var cursorColor: CellColor?
    public var cursorText: CellColor?
    public var selectionForeground: CellColor?
    public var selectionBackground: CellColor?
    /// ANSI and 256-color palette entries by index.
    public var palette: [Int: RGBColor]

    public init(
        background: RGBColor? = nil,
        foreground: RGBColor? = nil,
        cursorColor: CellColor? = nil,
        cursorText: CellColor? = nil,
        selectionForeground: CellColor? = nil,
        selectionBackground: CellColor? = nil,
        palette: [Int: RGBColor] = [:]
    ) {
        self.background = background
        self.foreground = foreground
        self.cursorColor = cursorColor
        self.cursorText = cursorText
        self.selectionForeground = selectionForeground
        self.selectionBackground = selectionBackground
        self.palette = palette
    }

    /// Reads a theme, skipping lines and values it does not understand.
    public static func parse(_ source: String) -> ColorScheme {
        var scheme = ColorScheme()
        for line in source.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "background": scheme.background = RGBColor(hex: value)
            case "foreground": scheme.foreground = RGBColor(hex: value)
            case "cursor-color": scheme.cursorColor = CellColor(themeValue: value)
            case "cursor-text": scheme.cursorText = CellColor(themeValue: value)
            case "selection-foreground": scheme.selectionForeground = CellColor(themeValue: value)
            case "selection-background": scheme.selectionBackground = CellColor(themeValue: value)
            case "palette":
                guard let split = value.firstIndex(of: "="),
                      let index = Int(value[..<split].trimmingCharacters(in: .whitespaces)),
                      (0...255).contains(index),
                      let color = RGBColor(hex: String(value[value.index(after: split)...]))
                else { continue }
                scheme.palette[index] = color
            default:
                continue
            }
        }
        return scheme
    }

    public func paletteColor(_ index: Int) -> RGBColor? { palette[index] }

    /// The 16 ANSI colors a theme picker shows, as far as the theme sets them.
    public var swatches: [RGBColor] { (0..<16).compactMap { palette[$0] } }
}

private extension CellColor {
    /// Theme files take only hex colors, unlike the terminal config.
    init?(themeValue value: String) {
        switch value {
        case "cell-foreground": self = .cellForeground
        case "cell-background": self = .cellBackground
        default:
            guard let color = RGBColor(hex: value) else { return nil }
            self = .rgb(color)
        }
    }
}

/// A color with transparency for the app's chrome, components from 0 to 1.
public struct ChromeColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(_ color: RGBColor, alpha: Double = 1) {
        self.init(red: color.red, green: color.green, blue: color.blue, alpha: alpha)
    }

    /// `0xRRGGBB` in sRGB, such as `ChromeColor(hex: 0x3B82F6)`.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(RGBColor(hex & 0xFF_FF_FF), alpha: alpha)
    }

    public func withAlpha(_ alpha: Double) -> ChromeColor {
        ChromeColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// HSL lightness, from 0 to 1.
    public var lightness: Double { (max(red, green, blue) + min(red, green, blue)) / 2 }

    /// Relative luminance as the theme uses it to pick text on an accent.
    public var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }

    /// The opaque color `amount` of the way from `background` to `self`.
    public func blended(over background: ChromeColor, amount: Double) -> ChromeColor {
        func mix(_ top: Double, _ bottom: Double) -> Double { top * amount + bottom * (1 - amount) }
        return ChromeColor(
            red: mix(red, background.red),
            green: mix(green, background.green),
            blue: mix(blue, background.blue)
        )
    }
}

/// The app chrome's colors, derived from a terminal theme: background, text,
/// borders, surfaces and accents all follow the chosen theme.
public struct ChromePalette: Equatable, Sendable {
    public var bg: ChromeColor
    public var fg: ChromeColor
    public var fgMuted: ChromeColor
    public var fgDim: ChromeColor
    public var surface: ChromeColor
    public var border: ChromeColor
    public var hover: ChromeColor
    public var accent: ChromeColor
    public var accentSoft: ChromeColor
    public var accentForeground: ChromeColor
    public var warning: ChromeColor
    public var danger: ChromeColor
    public var diffAdd: ChromeColor
    public var diffRemove: ChromeColor
    public var diffHunk: ChromeColor

    private static let fallbackBackground = RGBColor(0x23_27_21)
    private static let fallbackForeground = RGBColor(0xCE_D0_C6)
    private static let fallbackAccent = RGBColor(0xCD_A7_6B)

    public init(scheme: ColorScheme) {
        self.init(
            background: ChromeColor(scheme.background ?? Self.fallbackBackground),
            foreground: ChromeColor(scheme.foreground ?? Self.fallbackForeground),
            accent: ChromeColor(scheme.paletteColor(4) ?? Self.fallbackAccent),
            danger: ChromeColor(scheme.paletteColor(1) ?? RGBColor(0xEC_7B_79)),
            warning: ChromeColor(scheme.paletteColor(3) ?? RGBColor(0xE3_D1_70)),
            success: ChromeColor(scheme.paletteColor(2) ?? RGBColor(0x9A_BE_87)),
            hunk: scheme.paletteColor(6).map { ChromeColor($0) }
        )
    }

    /// A palette from its base roles; text tints, surfaces, borders and the
    /// accent's companions derive from them.
    public init(background: ChromeColor, foreground: ChromeColor, accent: ChromeColor,
                danger: ChromeColor, warning: ChromeColor, success: ChromeColor, hunk: ChromeColor? = nil) {
        bg = background
        fg = foreground
        fgMuted = foreground.withAlpha(0.65)
        fgDim = foreground.withAlpha(0.4)
        surface = foreground.withAlpha(0.08)
        border = foreground.blended(over: background, amount: 0.12)
        hover = foreground.withAlpha(0.06)
        self.accent = accent
        accentSoft = accent.withAlpha(0.1)
        accentForeground = Self.foreground(on: accent)
        self.warning = warning
        self.danger = danger
        diffAdd = success
        diffRemove = danger
        diffHunk = hunk ?? accent
    }

    /// Black or white, whichever reads on `fill`.
    public static func foreground(on fill: ChromeColor) -> ChromeColor {
        fill.luminance > 0.6 ? ChromeColor(red: 0, green: 0, blue: 0) : ChromeColor(red: 1, green: 1, blue: 1)
    }

    /// The palette with `overrides` applied. Overriding a base role such as the
    /// background, foreground or accent derives its tints again, unless those
    /// are overridden too.
    public func applying(_ overrides: ChromePaletteOverrides) -> ChromePalette {
        guard overrides != ChromePaletteOverrides() else { return self }
        let hunkFollowsAccent = diffHunk == accent
        var palette = ChromePalette(
            background: overrides.background ?? bg,
            foreground: overrides.foreground ?? fg,
            accent: overrides.accent ?? accent,
            danger: overrides.danger ?? danger,
            warning: overrides.warning ?? warning,
            success: overrides.success ?? diffAdd,
            hunk: hunkFollowsAccent ? nil : diffHunk
        )
        if overrides.foreground == nil {
            palette.fgMuted = fgMuted
            palette.fgDim = fgDim
            palette.surface = surface
            palette.hover = hover
            if overrides.background == nil { palette.border = border }
        }
        if overrides.accent == nil {
            palette.accentSoft = accentSoft
            palette.accentForeground = accentForeground
        }
        if overrides.danger == nil { palette.diffRemove = diffRemove }
        if let value = overrides.foregroundMuted { palette.fgMuted = value }
        if let value = overrides.foregroundDim { palette.fgDim = value }
        if let value = overrides.surface { palette.surface = value }
        if let value = overrides.border { palette.border = value }
        if let value = overrides.hover { palette.hover = value }
        if let value = overrides.accentSoft { palette.accentSoft = value }
        if let value = overrides.accentForeground { palette.accentForeground = value }
        if let value = overrides.diffAdd { palette.diffAdd = value }
        if let value = overrides.diffRemove { palette.diffRemove = value }
        return palette
    }

    /// Whether the background is light, so dark-on-light assets apply.
    public var isLight: Bool { bg.lightness >= 0.5 }

    /// The muted text color, as an alias the views name for secondary text.
    public var muted: ChromeColor { fgMuted }

    /// A surface drawn opaque over the background, for raised cards.
    public var raised: ChromeColor { surface.blended(over: bg, amount: surface.alpha) }
}

/// Colors that replace a theme's chrome colors, so an embedded conversation
/// can match its host app. Every color left nil keeps the theme's own.
public struct ChromePaletteOverrides: Equatable, Sendable {
    /// The canvas behind the conversation.
    public var background: ChromeColor?
    /// Body text; muted and dim text, surfaces, hover and borders derive from it.
    public var foreground: ChromeColor?
    /// Links, selection and primary buttons; its soft tint and the text drawn on it derive from it.
    public var accent: ChromeColor?
    public var danger: ChromeColor?
    public var warning: ChromeColor?
    /// Completed work and added lines.
    public var success: ChromeColor?
    public var foregroundMuted: ChromeColor?
    public var foregroundDim: ChromeColor?
    /// Pills, chips and raised fills.
    public var surface: ChromeColor?
    public var border: ChromeColor?
    public var hover: ChromeColor?
    public var accentSoft: ChromeColor?
    /// Text and glyphs drawn on the accent.
    public var accentForeground: ChromeColor?
    public var diffAdd: ChromeColor?
    public var diffRemove: ChromeColor?

    public init(
        background: ChromeColor? = nil, foreground: ChromeColor? = nil, accent: ChromeColor? = nil,
        danger: ChromeColor? = nil, warning: ChromeColor? = nil, success: ChromeColor? = nil,
        foregroundMuted: ChromeColor? = nil, foregroundDim: ChromeColor? = nil, surface: ChromeColor? = nil,
        border: ChromeColor? = nil, hover: ChromeColor? = nil, accentSoft: ChromeColor? = nil,
        accentForeground: ChromeColor? = nil, diffAdd: ChromeColor? = nil, diffRemove: ChromeColor? = nil
    ) {
        self.background = background
        self.foreground = foreground
        self.accent = accent
        self.danger = danger
        self.warning = warning
        self.success = success
        self.foregroundMuted = foregroundMuted
        self.foregroundDim = foregroundDim
        self.surface = surface
        self.border = border
        self.hover = hover
        self.accentSoft = accentSoft
        self.accentForeground = accentForeground
        self.diffAdd = diffAdd
        self.diffRemove = diffRemove
    }
}

/// A theme by name with its colors.
public struct ThemeEntry: Equatable, Sendable {
    public let name: String
    public let scheme: ColorScheme
    public init(name: String, scheme: ColorScheme) { self.name = name; self.scheme = scheme }
}

/// The bundled Ghostty themes plus the custom ones in the profile's
/// `themes/` folder, which replace bundled themes of the same name.
public struct ThemeCatalog: Sendable {
    public static let defaultDark = "Tab"
    public static let defaultLight = "Tab Light"

    /// Sorted with Tab's own themes first, then by name.
    public let entries: [ThemeEntry]
    /// Problems with custom themes, to show in Settings.
    public let errors: [String]

    public init(entries: [ThemeEntry], errors: [String] = []) {
        self.entries = entries
        self.errors = errors
    }

    /// Reads the bundled themes and those in `customDirectory`. Reads every
    /// file, so call it off the main thread.
    public static func load(customDirectory: URL?, includeBundled: Bool = true) -> ThemeCatalog {
        var schemes: [String: ColorScheme] = [:]
        var errors: [String] = []
        if includeBundled, let bundled = bundledDirectory {
            for (name, source) in readFiles(in: bundled, errors: &errors) {
                schemes[name] = ColorScheme.parse(source)
            }
        }
        if let customDirectory {
            try? FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true)
            for (file, source) in readFiles(in: customDirectory, errors: &errors) {
                let scheme = ColorScheme.parse(source)
                guard scheme.background != nil, scheme.foreground != nil else {
                    errors.append("Theme \(file) needs valid background and foreground colors")
                    continue
                }
                schemes[themeName(file)] = scheme
            }
        }
        let entries = schemes.map { ThemeEntry(name: $0.key, scheme: $0.value) }.sorted { left, right in
            let leftOwn = left.name == defaultDark || left.name == defaultLight
            let rightOwn = right.name == defaultDark || right.name == defaultLight
            if leftOwn != rightOwn { return leftOwn }
            let leftKey = left.name.lowercased()
            let rightKey = right.name.lowercased()
            if leftKey != rightKey { return leftKey < rightKey }
            return left.name < right.name
        }
        return ThemeCatalog(entries: entries, errors: errors)
    }

    /// The folder of bundled themes.
    public static var bundledDirectory: URL? {
        Bundle.module.resourceURL?.appendingPathComponent("Themes", isDirectory: true)
    }

    private static func readFiles(in directory: URL, errors: inout [String]) -> [(String, String)] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        } catch {
            errors.append("Could not load themes from \(directory.path): \(error.localizedDescription)")
            return []
        }
        var files: [(String, String)] = []
        for name in names where !name.hasPrefix(".") {
            let url = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            do {
                files.append((name, try String(contentsOf: url, encoding: .utf8)))
            } catch {
                errors.append("Could not read theme \(name): \(error.localizedDescription)")
            }
        }
        return files
    }

    /// A theme by name, or by its file name such as `Dracula.conf`.
    public func find(_ name: String) -> ThemeEntry? {
        for candidate in [name, Self.themeName(name)] {
            if let entry = entries.first(where: { $0.name == candidate }) { return entry }
        }
        return nil
    }

    /// The theme for the light or dark appearance, falling back to Tab's own.
    public func selected(darkTheme: String, lightTheme: String, dark: Bool) -> ThemeEntry? {
        find(dark ? darkTheme : lightTheme) ?? find(dark ? Self.defaultDark : Self.defaultLight)
    }

    /// The colors and chrome palette for the appearance.
    public func resolve(darkTheme: String, lightTheme: String, dark: Bool) -> (ColorScheme, ChromePalette) {
        let scheme = selected(darkTheme: darkTheme, lightTheme: lightTheme, dark: dark)?.scheme ?? ColorScheme()
        return (scheme, ChromePalette(scheme: scheme))
    }

    static func themeName(_ file: String) -> String {
        for suffix in [".conf", ".theme"] where file.hasSuffix(suffix) {
            return String(file.dropLast(suffix.count))
        }
        return file
    }
}
