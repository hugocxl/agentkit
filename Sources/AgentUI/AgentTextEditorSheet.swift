import AgentCore
import AppKit
import Combine

/// A nonblocking multiline editor. Cancelling never mutates the underlying draft.
@MainActor
final class AgentTextEditorSheet {
    let alert = NSAlert()
    let editor = NSTextView()
    let settings = NSButton(checkboxWithTitle: "Use current model, reasoning effort and plan mode", target: nil, action: nil)
    private var themeObservation: AnyCancellable?

    init(title: String, detail: String, text: String, theme: AgentTheme, showsSettings: Bool = false, allowsDelete: Bool = false) {
        alert.messageText = title
        alert.informativeText = detail
        alert.window.appearance = theme.nsAppearance
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: showsSettings ? 230 : 194))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: showsSettings ? 36 : 0, width: 440, height: 194))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        editor.isRichText = false
        editor.font = AppFont.body
        editor.textColor = theme.fg
        editor.backgroundColor = theme.card
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.frame = NSRect(x: 0, y: 0, width: 438, height: 192)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.string = text
        editor.setAccessibilityLabel(title)
        scroll.documentView = editor
        content.addSubview(scroll)
        if showsSettings {
            settings.frame = NSRect(x: 0, y: 0, width: 440, height: 28)
            content.addSubview(settings)
        }
        alert.accessoryView = content
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if allowsDelete { alert.addButton(withTitle: "Delete") }
        observe(theme)
    }

    /// Shows the editor in `theme` from now on, keeping what was typed.
    func follow(_ theme: AgentTheme) {
        apply(theme)
        observe(theme)
    }

    private func apply(_ theme: AgentTheme) {
        alert.window.appearance = theme.nsAppearance
        editor.textColor = theme.fg
        editor.backgroundColor = theme.card
    }

    /// Follows `theme` as it changes in place too, as for the system appearance.
    private func observe(_ theme: AgentTheme) {
        themeObservation = theme.changes.sink { [weak self, weak theme] in
            guard let self, let theme else { return }
            MainActor.assumeIsolated { self.apply(theme) }
        }
    }

    func present(in window: NSWindow, completion: @escaping (NSApplication.ModalResponse, String, Bool) -> Void) {
        alert.beginSheetModal(for: window) { [self] response in
            completion(response, editor.string, settings.state == .on)
        }
        alert.window.makeFirstResponder(editor)
    }

    func close() {
        if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .alertSecondButtonReturn) }
    }
}
