import AgentCore
import AppKit

/// One agent's own steps, its tool calls and text, in a nested transcript. The pane
/// reads them again when its snapshot says the agent's step count changed, so a
/// running agent's window follows it without polling. A background shell's one step is
/// its command and the end of its output, which has no step count, so its window reads
/// it again every few seconds while the shell runs and the window is open.
@MainActor
final class AgentSubagentStepsWindow: NSWindowController, NSWindowDelegate {
    typealias Fetch = (String) async throws -> AgentSubagentSteps
    let toolUseID: String
    private let fetch: Fetch
    private let scroll = NSScrollView()
    private let transcript = AgentTranscriptDocument(frame: .zero)
    let message = makeLabel("", font: AppFont.body)
    private let background = ThemedBackground(color: { $0.paneBackground })
    /// What the window shows, which owns a diagram expanded from the steps.
    let content: AgentSubagentStepsContent
    private var loadTask: Task<Void, Never>?
    private var reloadPending = false
    private var outputRefresh: Timer?
    private var isShell = false
    private(set) var items: [AgentChatItem] = []
    /// The step count the shown items were read at.
    private(set) var loadedSteps: Int?
    var onClose: (() -> Void)?

    /// `remoteImages` is the setting of the conversation the agent works in.
    init(subagent: AgentSubagent, toolUseID: String, theme: AgentTheme,
         remoteImages: @escaping () -> RemoteImagePolicy = { AgentSettings().remoteImages }, fetch: @escaping Fetch) {
        self.toolUseID = toolUseID
        self.fetch = fetch
        content = AgentSubagentStepsContent(theme: theme)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 240)
        window.delegate = self
        window.appearance = theme.nsAppearance
        transcript.isNested = true
        transcript.theme = theme
        background.theme = theme
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = transcript
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        message.alignment = .center
        message.textColor = theme.fgDim
        // Its plain controls and frame follow the theme changing in place, as for the system appearance.
        background.onColorsChange = { [weak self] in self?.applyChrome() }
        background.addSubview(scroll)
        background.addSubview(message)
        scroll.translatesAutoresizingMaskIntoConstraints = true
        message.translatesAutoresizingMaskIntoConstraints = true
        scroll.autoresizingMask = [.width, .height]
        message.autoresizingMask = [.width, .minYMargin]
        let scope = AgentRemoteImageScopeView(remoteImages: remoteImages)
        content.frame = scope.bounds
        content.autoresizingMask = [.width, .height]
        scope.addSubview(content)
        background.frame = content.bounds
        background.autoresizingMask = [.width, .height]
        content.addSubview(background)
        window.contentView = scope
        scroll.frame = background.bounds.insetBy(dx: 16, dy: 0)
        message.frame = NSRect(x: 0, y: background.bounds.midY - 10, width: background.bounds.width, height: 20)
        update(subagent)
        window.center()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The theme the window draws in.
    var theme: AgentTheme { transcript.theme }

    /// Shows this window in `theme` from now on, as its conversation does.
    func follow(_ theme: AgentTheme) {
        guard transcript.theme !== theme else { return }
        transcript.theme = theme
        transcript.themeDidChange()
        background.theme = theme
        background.themeDidChange()
        applyChrome()
        content.follow(theme)
    }

    private func applyChrome() {
        window?.appearance = theme.nsAppearance
        message.textColor = theme.fgDim
    }

    /// Takes the agent's latest listing and reads its steps again when they changed.
    func update(_ subagent: AgentSubagent) {
        let state = subagent.status == .running ? "running" : subagent.status.rawValue
        window?.title = subagent.description + " · " + state
        isShell = subagent.agentType == "Shell"
        if isShell {
            let running = subagent.status == .running
            // A shell that just ended has its last output to read.
            if !running, outputRefresh != nil { reload() }
            followOutput(running)
        }
        if let steps = subagent.steps, steps != loadedSteps { reload() }
    }

    private func followOutput(_ running: Bool) {
        guard running != (outputRefresh != nil) else { return }
        outputRefresh?.invalidate()
        outputRefresh = running ? Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        } : nil
    }

    func reload() {
        guard loadTask == nil else { reloadPending = true; return }
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.loadTask = nil
                if self.reloadPending { self.reloadPending = false; self.reload() }
            }
            do {
                let steps = try await self.fetch(self.toolUseID)
                guard !Task.isCancelled else { return }
                self.show(steps.items)
            } catch is CancellationError {
            } catch {
                self.showMessage(error.localizedDescription)
            }
        }
    }

    private func show(_ items: [AgentChatItem]) {
        // A shell's output is what its window is for, so it opens expanded.
        if isShell, self.items.isEmpty, let id = items.first?.id {
            transcript.rowStates["activity:" + id] = AgentTimelineRowState(toolExpandedIDs: [id])
        }
        self.items = items
        loadedSteps = items.count
        message.isHidden = !items.isEmpty
        if items.isEmpty { message.stringValue = isShell ? "No output yet." : "No steps yet. They appear here as the agent works." }
        let following = scroll.contentView.bounds.maxY >= transcript.frame.height - 24
        transcript.update(items, omittedCount: 0)
        transcript.reflow(viewportWidth: scroll.contentSize.width)
        _ = transcript.updateViewport(scroll.contentView.bounds, followingEnd: following)
        if following { scroll.contentView.scroll(to: NSPoint(x: 0, y: transcript.viewportOrigin)) }
    }

    private func showMessage(_ text: String) {
        message.isHidden = false
        message.stringValue = text
    }

    @objc private func scrolled() {
        guard !transcript.isUpdatingViewport else { return }
        transcript.updateViewport(scroll.contentView.bounds, followingEnd: false)
    }

    func windowDidResize(_ notification: Notification) {
        transcript.reflow(viewportWidth: scroll.contentSize.width)
    }

    func windowWillClose(_ notification: Notification) {
        content.expanded?.close()
        loadTask?.cancel()
        outputRefresh?.invalidate()
        outputRefresh = nil
        NotificationCenter.default.removeObserver(self)
        onClose?()
    }
}

/// An agent's steps as their window shows them: it owns a diagram expanded from them, which
/// follows the window's theme and closes with it.
@MainActor
final class AgentSubagentStepsContent: NSView, AgentMediaExpanding {
    private(set) var theme: AgentTheme
    /// A diagram of the steps expanded over them.
    private(set) var expanded: AgentMediaPreviewWindow?

    init(theme: AgentTheme) {
        self.theme = theme
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func expand(_ preview: AgentMediaPreviewWindow) {
        expanded?.close()
        preview.follow(theme)
        preview.onClose = { [weak self, weak preview] in
            if let self, self.expanded === preview { self.expanded = nil }
        }
        expanded = preview
        preview.present(in: window)
    }

    /// Draws in `theme` from now on, as the window does, the expanded diagram too.
    func follow(_ theme: AgentTheme) {
        self.theme = theme
        expanded?.follow(theme)
    }
}
