import AgentCore
import AppKit

/// A short message among the window's notices that hides itself after a
/// few seconds.
public enum Toast {
    public enum Style: Sendable {
        case info, success, error
    }

    /// How long a toast of `style` stays.
    static func lifetime(_ style: Style) -> TimeInterval { style == .error ? 6 : 4 }

    static func notice(_ message: String, style: Style) -> Notice {
        switch style {
        case .info: return Notice(tone: .neutral, icon: .icon(.infoFill), message: message)
        case .success: return Notice(tone: .success, icon: .icon(.circleCheckFill), message: message)
        case .error: return Notice(tone: .danger, icon: .icon(.exclamationCircleFill), message: message)
        }
    }

    /// Shows `message` where the host of `view`'s conversation shows notices, else
    /// among the notices of `view`'s window, else in the conversation's own.
    @MainActor
    public static func show(_ message: String, style: Style = .info, in view: NSView) {
        let pane = sequence(first: view, next: { $0.superview }).lazy.compactMap({ $0 as? AgentPaneView }).first
        if let pane, let host = pane.actions.project as? AgentHostActions, host.showNotice(message, style: style) { return }
        guard let stack = view.window?.contentView?.subviews.lazy.compactMap({ $0 as? NoticeStack }).first ?? pane?.ownNotices() else { return }
        stack.show(notice(message, style: style), lifetime: lifetime(style))
    }
}

/// A confirmation asked as a sheet on a window, or as a modal alert when
/// there is no window.
@MainActor
public enum ConfirmSheet {
    /// Asks `title`; `completion` gets whether the user confirmed.
    public static func present(
        on window: NSWindow?,
        title: String,
        message: String,
        confirm: String,
        destructive: Bool = false,
        theme: AgentTheme? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        let theme = theme ?? .shared
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .critical : .warning
        let button = alert.addButton(withTitle: confirm)
        button.hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        alert.window.appearance = theme.nsAppearance
        guard let window else {
            completion(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }
}
