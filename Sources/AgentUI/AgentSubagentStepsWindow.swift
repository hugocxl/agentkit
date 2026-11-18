import AgentCore
import AppKit

/// One agent's own steps, its tool calls and text, in a nested transcript. The pane
/// reads them again when its snapshot reports a new steps revision (a step's text or
/// result changing, a tool finishing, old steps giving way) or the agent ending, so a
/// running agent's window follows it without polling; a server that predates revisions
/// reports a step count instead. Reads that come due while one is in flight make a single
/// read after it. Earlier steps load a page at a time above the newest, and steps the
/// server no longer keeps are counted there. A background shell's one step is its command
/// and the end of its output, which has no step count, so its window reads it again every
/// few seconds while the shell runs and the window is open.
@MainActor
final class AgentSubagentStepsWindow: NSWindowController, NSWindowDelegate {
    typealias Fetch = (String) async throws -> AgentSubagentSteps
    let toolUseID: String
    private let fetch: Fetch
    /// Reads the steps before a position; nil when the server can't.
    var fetchEarlier: ((String, Int) async throws -> AgentSubagentSteps)?
    private let scroll = NSScrollView()
    let transcript = AgentTranscriptDocument(frame: .zero)
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
    /// The steps revision the shown items were read at, and the latest the pane reported.
    private(set) var loadedRevision: UInt64?
    private var reportedRevision: UInt64?
    private var lastStatus: AgentSubagent.Status?
    /// The newest page, and pages loaded above it from position `earlierStart`.
    private(set) var newest: AgentSubagentSteps?
    private(set) var earlier: [AgentChatItem] = []
    private(set) var earlierStart: Int?
    private var earlierTask: Task<Void, Never>?
    /// How many reads were made, for tests.
    private(set) var readCount = 0
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
        update(subagent, reading: false)
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
    func update(_ subagent: AgentSubagent) { update(subagent, reading: true) }

    private func update(_ subagent: AgentSubagent, reading: Bool) {
        let state = subagent.status == .running ? "running" : subagent.status.rawValue
        window?.title = subagent.description + " · " + state
        isShell = subagent.agentType == "Shell"
        let ended = lastStatus == .running && subagent.status != .running
        lastStatus = subagent.status
        reportedRevision = subagent.stepsRevision ?? reportedRevision
        guard reading else {
            if isShell { followOutput(subagent.status == .running) }
            return
        }
        if isShell {
            let running = subagent.status == .running
            // A shell that just ended has its last output to read.
            if !running, outputRefresh != nil { reload() }
            followOutput(running)
        }
        if ended {
            reload()
        } else if let revision = subagent.stepsRevision {
            if revision != loadedRevision { reload() }
        } else if let steps = subagent.steps, steps != loadedSteps {
            reload()
        }
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
                self.readCount += 1
                let steps = try await self.fetch(self.toolUseID)
                guard !Task.isCancelled else { return }
                self.show(steps)
            } catch is CancellationError {
            } catch {
                self.showMessage(error.localizedDescription)
            }
        }
    }

    private func show(_ steps: AgentSubagentSteps) {
        // A shell's output is what its window is for, so it opens expanded.
        if isShell, self.items.isEmpty, let id = steps.items.first?.id {
            transcript.rowStates["activity:" + id] = AgentTimelineRowState(toolExpandedIDs: [id])
        }
        // Loaded pages stay above the newest while they join it: the steps that left the
        // newest page join them, and pages that no longer reach it are let go.
        if let previous = newest, let earlierStart, let start = steps.start, let previousStart = previous.start {
            if start > previousStart + previous.items.count || earlierStart > start {
                earlier = []; self.earlierStart = nil
            } else {
                let kept = Set(steps.items.map(\.id))
                let known = Set(earlier.map(\.id))
                earlier += previous.items.filter { !kept.contains($0.id) && !known.contains($0.id) }
            }
        }
        newest = steps
        loadedSteps = steps.total ?? steps.items.count
        loadedRevision = steps.revision ?? reportedRevision
        render()
    }

    /// Lays out the loaded pages and the newest one, with what's above them.
    private func render() {
        guard let steps = newest else { return }
        let shown = Set(steps.items.map(\.id))
        items = earlier.filter { !shown.contains($0.id) } + steps.items
        message.isHidden = !items.isEmpty
        if items.isEmpty {
            message.stringValue = steps.unavailable == true ? "This agent's steps weren't saved, so they can't be shown."
                : isShell ? "No output yet." : "No steps yet. They appear here as the agent works."
        }
        let above = earlierStart ?? steps.start ?? 0
        let omitted = steps.omitted ?? 0
        let loadable = fetchEarlier != nil && above > omitted
        transcript.earlierDescription = { count in
            let steps = count == 1 ? "1 earlier step" : "\(count) earlier steps"
            return loadable ? steps + (count == 1 ? " isn't" : " aren't") + " shown."
                : steps + (count == 1 ? " wasn't" : " weren't") + " kept by the server."
        }
        transcript.onEarlier = loadable ? { [weak self] in self?.loadEarlier() } : nil
        let following = scroll.contentView.bounds.maxY >= transcript.frame.height - 24
        transcript.update(items, omittedCount: above)
        transcript.reflow(viewportWidth: scroll.contentSize.width)
        _ = transcript.updateViewport(scroll.contentView.bounds, followingEnd: following)
        if following { scroll.contentView.scroll(to: NSPoint(x: 0, y: transcript.viewportOrigin)) }
    }

    /// Loads the page of steps above those shown.
    func loadEarlier() {
        guard earlierTask == nil, let fetchEarlier, let before = earlierStart ?? newest?.start, before > (newest?.omitted ?? 0) else { return }
        earlierTask = Task { [weak self] in
            defer { self?.earlierTask = nil }
            guard let self else { return }
            do {
                let page = try await fetchEarlier(self.toolUseID, before)
                // The newest page moved past what this page joins: it's read again from there.
                guard !Task.isCancelled, (self.earlierStart ?? self.newest?.start) == before else { return }
                guard let start = page.start, start < before, !page.items.isEmpty else {
                    self.fetchEarlier = nil
                    return self.render()
                }
                let known = Set(self.earlier.map(\.id))
                self.earlier = page.items.filter { !known.contains($0.id) } + self.earlier
                self.earlierStart = start
                self.render()
            } catch is CancellationError {
            } catch {
                self.fetchEarlier = nil
                self.render()
                self.showMessage(error.localizedDescription)
            }
        }
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
        earlierTask?.cancel()
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
