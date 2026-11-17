import AgentCore
import AppKit
import Combine

/// A native borderless glyph button, as in pane headers and panels: a 16pt
/// glyph in a 24pt square by default that shows the system hover bezel.
/// `onPress` runs on click.
public final class IconButton: NSButton {
    public var icon: AppIcon { didSet { updateImage() } }
    public var onPress: (() -> Void)?
    /// Tints the glyph with the accent, for toggles that are on.
    public var isActive = false { didSet { updateTint() } }
    public let side: CGFloat
    /// The theme the glyph is tinted in; it follows that theme's changes.
    public var theme: AgentTheme = .shared {
        didSet {
            guard theme !== oldValue else { return }
            palette.observe(self, theme: theme) { [weak self] in self?.updateTint() }
            updateTint()
        }
    }
    private let palette = PaletteObserver()

    public init(_ icon: AppIcon, label: String, side: CGFloat = 24, action: (() -> Void)? = nil) {
        self.icon = icon
        self.side = side
        onPress = action
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        bezelStyle = .accessoryBarAction
        showsBorderOnlyWhileMouseInside = true
        refusesFirstResponder = true
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        title = ""
        toolTip = label
        setAccessibilityLabel(label)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).isActive = true
        heightAnchor.constraint(equalToConstant: side).isActive = true
        target = self
        self.action = #selector(pressed)
        updateImage()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    private func updateImage() {
        updateTint()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        palette.observe(self, theme: theme) { [weak self] in self?.updateTint() }
    }

    /// Draws the glyph pre-tinted in the theme's colors: AppKit would wash
    /// out a template image in an inactive window, unlike the theme's chrome.
    private func updateTint() {
        image = icon.image(size: Metrics.glyph, theme: theme, tint: isActive ? theme.accent : theme.fgMuted)
    }

    @objc private func pressed() {
        onPress?()
    }
}

/// A glyph in a circle that fills while hovered or pressed, the chrome's
/// button in the sidebars and pane headers, with a glass tooltip showing its
/// label and `shortcut`. Subclasses handle `pressed()`.
public final class PillButton: NSButton {
    public enum Style: Sendable {
        /// The standard push button.
        case normal
        /// Accent bezel, for the window's one main action.
        case primary
        /// Marked destructive, for actions that remove something.
        case destructive
        /// No bezel until hovered, such as Reset beside a shortcut.
        case plain
    }

    public var style: Style { didSet { applyStyle() } }
    public var onPress: (() -> Void)?
    public var onFocusChange: ((Bool) -> Void)?

    public init(_ title: String, style: Style = .normal, action: (() -> Void)? = nil) {
        self.style = style
        onPress = action
        super.init(frame: .zero)
        self.title = title
        setButtonType(.momentaryPushIn)
        translatesAutoresizingMaskIntoConstraints = false
        target = self
        self.action = #selector(pressed)
        applyStyle()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    public override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }

    private func applyStyle() {
        bezelStyle = style == .plain ? .accessoryBarAction : .push
        showsBorderOnlyWhileMouseInside = style == .plain
        bezelColor = style == .primary ? .controlAccentColor : nil
        hasDestructiveAction = style == .destructive
        contentTintColor = style == .destructive ? .systemRed : nil
    }

    @objc private func pressed() {
        perform()
    }

    /// Runs the action as a click would.
    public func perform() {
        guard isEnabled else { return }
        onPress?()
    }
}

extension NSButton {
    /// Shows the title in `color`, which AppKit keeps in inactive windows,
    /// unlike its own label colors.
    func setTitleColor(_ color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = lineBreakMode
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: color,
            .font: font ?? AppFont.body,
            .paragraphStyle: paragraph,
        ])
    }
}

extension NSImage {
    /// The template image filled with `color`.
    func tinted(_ color: NSColor) -> NSImage {
        guard isTemplate else { return self }
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return image
    }
}
