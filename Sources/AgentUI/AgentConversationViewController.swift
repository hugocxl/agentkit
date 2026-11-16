import AppKit
import AgentCore

/// A native conversation and composer, backed by a local runtime or a host transport.
/// Retain the controller while work runs. Removing its view does not stop the agent;
/// call `closeConversation()` for an explicit close and `dispose()` to release the UI.
@MainActor
public final class AgentConversationViewController: NSViewController {
    let controller: AgentPaneController
    private var observation: Task<Void, Never>?
    public let connection: AgentConnection

    /// Whether keyboard focus is in the composer rather than the transcript.
    public var composerHasFocus: Bool { controller.view.window?.firstResponder === controller.surface.composer }
    public var snapshot: AgentChatSnapshot? { controller.snapshot }
    public var selectedProvider: AgentChatProvider { controller.selection.provider }
    public var conversationTitle: String { controller.title }
    public var conversationIcon: NSImage? { controller.icon }
    public var theme: AgentTheme {
        get { controller.surface.theme }
        set { controller.surface.theme = newValue; controller.surface.themeDidChange() }
    }
    /// Called when the title or other conversation presentation changes.
    public var onChange: (() -> Void)? {
        get { controller.titleDidChange }
        set { controller.titleDidChange = newValue }
    }
    public var onTitleChange: ((String) -> Void)? {
        get { controller.onTitleChange }
        set { controller.onTitleChange = newValue }
    }
    public var onProviderChange: (() -> Void)? {
        get { controller.onProviderChange }
        set { controller.onProviderChange = newValue }
    }
    public var onNewConversation: (() -> Void)? {
        get { controller.onNewConversation }
        set { controller.onNewConversation = newValue }
    }
    public var onShowConversation: ((AgentChatSnapshot) -> Void)? {
        get { controller.showConversation }
        set { controller.showConversation = newValue }
    }
    public var confirmClose: (() async -> Bool)? {
        get { controller.confirmClose }
        set { controller.confirmClose = newValue }
    }
    public var connectionNotice: (() -> String?)? {
        get { controller.connectionNotice }
        set { controller.connectionNotice = newValue }
    }
    public var shortcutDisplay: ((AgentShortcut) -> String?)? {
        get { controller.keyDisplay }
        set { controller.keyDisplay = newValue }
    }

    /// Builds the full conversation surface without launching a provider process.
    /// `host` supplies application-specific navigation and file services.
    public init(connection: AgentConnection, theme: AgentTheme? = nil, host: AgentHostServices? = nil) {
        self.connection = connection
        controller = AgentPaneController(session: connection.session, project: connection.project,
                                         provider: connection.provider, request: connection.request)
        super.init(nibName: nil, bundle: nil)
        var host = host ?? AgentHostServices(directory: { connection.workingDirectory?.path },
                                            isLocal: { connection.workingDirectory != nil })
        if host.readFile == nil, let read = connection.files { host.readFile = { try await read($0) } }
        if host.loadFiles == nil, let read = connection.files {
            host.loadFiles = {
                guard case .fileList(let list) = try await read(.init(project: connection.project, action: .searchFiles(limit: 10_000))) else { return [] }
                return list.paths
            }
        }
        controller.bind(connection, host: host, theme: theme ?? AgentTheme.shared)
        // Subscribe before the initial read, so a fast backend cannot lose an update.
        let changes = connection.observe()
        observation = Task { [weak self] in
            for await change in changes {
                guard !Task.isCancelled, let self else { return }
                self.controller.sessionChanged(session: change.session, revision: change.revision)
            }
        }
    }

    public required init?(coder: NSCoder) { nil }
    deinit { observation?.cancel() }
    public override func loadView() { view = controller.view }
    public override func viewDidAppear() { super.viewDidAppear(); controller.didShow() }
    public override func viewDidDisappear() { super.viewDidDisappear(); controller.didHide() }

    /// Refreshes authoritative state. No polling timer is used.
    public func refresh() { controller.refresh() }
    public func connectionChanged() { controller.connectionChanged() }
    public func sessionChanged(session: SessionId, revision: UInt64) { controller.sessionChanged(session: session, revision: revision) }
    public func focusComposer() { controller.focusContent() }
    public func stopVoice() { controller.didHide() }
    public func canClose() async -> Bool { await controller.willClose() }
    /// Stops the conversation and cancels queued prompts after the host has approved closing it.
    public func closeConversation() async -> Bool { await controller.commitClose() }
    public func flushDraft() async throws { try await controller.flushDraft() }
    public func dispose() { observation?.cancel(); observation = nil; controller.dispose() }
    @discardableResult
    public func perform(_ command: AgentShortcut) -> Bool { controller.performConversationShortcut(command) }
    public func attachFiles(_ urls: [URL]) { controller.attachFiles(urls) }

    /// Adds text without submitting it. The expected prompt protects an edited draft.
    public func appendToDraft(_ text: String, expectedPrompt: String) throws {
        try AgentConversationTemplateAction.append(text, expectedPrompt: expectedPrompt, surface: controller.surface)
    }
    public func restorePreferences(defaults: AgentComposerPreferences?, draft: AgentComposerPreferences?,
                                   save: @escaping (AgentComposerPreferences?) -> Void) {
        controller.restorePreferences(defaults: defaults, draft: draft, save: save)
    }
    /// Waits for the requested transcript before scrolling to the quoted text.
    public func revealCitation(_ citation: AgentAssistantCitation, snapshot: AgentChatSnapshot) async throws {
        try await AgentConversationSavedNavigation.awaitTranscript(controller, snapshot: snapshot)
        guard controller.surface.revealCitation(citation) else { throw ModelError("The quoted text could not be located.") }
    }
}
