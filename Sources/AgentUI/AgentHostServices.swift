import AppKit
import AgentCore

/// Integrations supplied by the application embedding a conversation.
/// Closures run on the main actor; file reads should perform their work asynchronously.
@MainActor
public struct AgentHostServices {
    public var directory: () -> String?
    public var isLocal: () -> Bool
    public var readFile: ((FilesRequest) async throws -> FilesReply)?
    public var supportsFileWriteParents: () -> Bool = { false }
    public var supportsRangedReads: () -> Bool = { true }
    public var openFile: ((String, Int?, Int?) throws -> Void)?
    public var openBrowser: ((URL) throws -> Void)?
    public var runCommand: ((String) -> Void)?
    public var openConversation: ((SessionId, ProjectId?, AgentAssistantCitation?) async throws -> Void)?
    public var pullRequestPreview: ((URL) async throws -> GitPullRequestPreview)?
    public var repositoryOrigin: (() async throws -> String?)?
    public var workspaceDescription: (() -> String?)?
    public var loadThreads: (() async throws -> [AgentMentionThread])?
    public var loadFiles: (() async throws -> [String])?
    public var remoteImages: () -> RemoteImagePolicy = { AgentSettings().remoteImages }
    /// Shows a short notice, such as an image copy's progress or failure, where the
    /// host shows its own; without it AgentKit uses the notice stack in the window.
    public var showNotice: ((String, Toast.Style) -> Void)?
    /// Opens the host's agent settings, on the page of the provider ID it names, if any:
    /// where providers are added, configured, installed and updated. With it, a new
    /// conversation that has no provider to start with offers to add one.
    public var openAgentSettings: ((String?) -> Void)?
    /// Opens the host's agent settings with its Add Provider form.
    public var addAgentProvider: (() -> Void)?

    /// Creates host services. Omitted integrations report that the action is unavailable.
    public init(directory: @escaping () -> String? = { nil }, isLocal: @escaping () -> Bool = { false }) {
        self.directory = directory; self.isLocal = isLocal
    }
}

@MainActor
final class AgentHostActions: AgentConversationProjectActions {
    private weak var surface: AgentPaneView?
    private let services: AgentHostServices
    private let session: SessionId
    private(set) var preview: AgentConversationMediaWindow?
    /// Set once the conversation goes: it opens no preview after.
    private(set) var closed = false
    private var metadataTask: Task<Void, Never>?
    private var metadataLoaded = false
    private var metadataGeneration: UInt64 = 0

    init(surface: AgentPaneView, session: SessionId, services: AgentHostServices) {
        self.surface = surface; self.session = session; self.services = services
    }

    deinit { metadataTask?.cancel() }
    var isLocal: Bool { services.isLocal() }

    private func scope() throws -> AgentConversationFileActions.Scope {
        guard let snapshot = surface?.snapshot, snapshot.session == session,
              let directory = services.directory() else { throw ModelError("The conversation's working directory is unavailable.") }
        return .init(project: snapshot.project, session: session, directory: directory)
    }
    private func reader() throws -> AgentConversationFileActions.Read {
        guard let read = services.readFile else { throw ModelError("File access is unavailable in this application.") }
        return read
    }
    func connectionChanged() {
        metadataGeneration &+= 1
        metadataTask?.cancel(); metadataTask = nil; metadataLoaded = false
    }
    /// Reads the repository identity once per connection. A host's answer, including
    /// an error such as a folder outside Git, holds until the connection changes;
    /// only a failure without an error code, such as a dropped connection, retries.
    func refreshProjectMetadata() {
        guard !metadataLoaded, metadataTask == nil, let fetch = services.repositoryOrigin else { return }
        let generation = metadataGeneration
        metadataLoaded = true
        metadataTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.metadataGeneration == generation { self.metadataTask = nil } }
            do {
                let origin = try await fetch()
                try Task.checkCancellation()
                self.surface?.linkServices.pullRequestHosts = AgentPullRequestLink.hosts(origin: origin)
            } catch is CancellationError {
            } catch {
                if agentErrorCode(error) == nil, self.metadataGeneration == generation { self.metadataLoaded = false }
            }
        }
    }
    /// False when the host shows no notices, so AgentKit shows its own.
    func showNotice(_ message: String, style: Toast.Style) -> Bool {
        guard let show = services.showNotice else { return false }
        show(message, style)
        return true
    }
    func searchProjectEntries(_ query: String, limit: Int) async throws -> AgentConversationFileActions.Entries {
        try await AgentConversationFileActions.searchProjectEntries(query, limit: limit, scope: scope(), read: reader())
    }
    func filesystemMetadata(_ paths: [String]) async throws -> [AgentConversationFileActions.Metadata?] {
        try await AgentConversationFileActions.filesystemMetadata(paths, scope: scope(), read: reader())
    }
    func workspaceMedia(_ path: String, cwd: String?) async throws -> AgentConversationFileActions.Media {
        try await AgentConversationFileActions.media(path, cwd: cwd, scope: scope(), ranged: services.supportsRangedReads(), read: reader())
    }
    func writeProjectFile(_ relativePath: String, contents: String, cwd: String?) async throws -> String {
        try await AgentConversationFileActions.writeProjectFile(relativePath, contents: contents, cwd: cwd, scope: scope(), createParents: services.supportsFileWriteParents(), read: reader())
    }
    func pullRequestPreview(_ url: URL) async throws -> GitPullRequestPreview {
        guard let fetch = services.pullRequestPreview else { throw ModelError("Pull request previews are unavailable.") }
        return try await fetch(url)
    }
    func openEditor(_ target: String, reveal: Bool) throws {
        let scope = try scope()
        guard let position = AgentConversationFileTarget.parse(target) else { throw ModelError("Invalid file target.") }
        let relative = try AgentConversationFileActions.resolve(position.path, scope: scope)
        if reveal {
            guard isLocal else { throw ModelError("Finder cannot reveal remote files.") }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: scope.directory).appendingPathComponent(relative)])
        } else if let open = services.openFile {
            try open(relative, position.line, position.column)
        } else if isLocal {
            guard NSWorkspace.shared.open(URL(fileURLWithPath: scope.directory).appendingPathComponent(relative)) else {
                throw ModelError("No application could open this file.")
            }
        } else { throw ModelError("The host has no file editor.") }
    }
    func openFileInBrowser(_ path: String) throws {
        guard isLocal else { throw ModelError("Remote files cannot open in a local browser.") }
        let scope = try scope()
        let url = URL(fileURLWithPath: scope.directory).appendingPathComponent(try AgentConversationFileActions.resolve(path, scope: scope))
        guard ["html", "htm"].contains(url.pathExtension.lowercased()), NSWorkspace.shared.open(url) else {
            throw ModelError("The HTML file could not be opened.")
        }
    }
    func openBrowser(_ url: URL) throws {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw ModelError("Invalid web address.") }
        if let open = services.openBrowser { try open(url) }
        else if !NSWorkspace.shared.open(url) { throw ModelError("No browser could open this link.") }
    }
    func previewFile(_ path: String) async throws {
        let scope = try scope(), read = try reader()
        let relative = try AgentConversationFileActions.resolve(path, scope: scope)
        guard case .info(let info) = try await read(.init(project: scope.project, action: .stat(ServerPath(relative)))), !info.isDirectory else {
            throw ModelError("The file preview is unavailable.")
        }
        let loaded = try await AgentConversationFileActions.resource(relative, size: info.size,
            mimeType: AgentConversationFileActions.mimeType(path: relative), scope: scope,
            ranged: services.supportsRangedReads(), read: read)
        try Task.checkCancellation()
        guard !closed else { return }
        let next = try AgentConversationMediaWindow(resource: loaded.resource, name: (relative as NSString).lastPathComponent)
        preview?.close(); preview = next; next.showWindow(nil)
    }

    /// Closes the file preview it opened, as when the conversation goes, and opens none after.
    func close() {
        closed = true
        preview?.close()
        preview = nil
    }
    func openConversation(_ target: SessionId, project: ProjectId?, citation: AgentAssistantCitation?) async throws {
        guard let open = services.openConversation else { throw ModelError("Conversation navigation is unavailable in this application.") }
        try await open(target, project, citation)
    }
}

extension Notification.Name {
    /// Posted after a host or AgentKit's agent settings change the configured providers,
    /// so every open conversation reloads its model menu.
    public static let agentProviderSettingsDidChange = Notification.Name("AgentKit.agentProviderSettingsDidChange")
}
