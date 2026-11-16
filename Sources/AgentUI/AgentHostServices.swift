import AppKit
import AgentCore

/// Integrations supplied by the application embedding a conversation.
/// Closures run on the main actor; file reads should perform their work asynchronously.
@MainActor
public struct AgentHostServices {
    public var directory: () -> String?
    public var isLocal: () -> Bool
    public var readFile: ((FilesRequest) async throws -> FilesReply)?
    public var supportsRangedReads: () -> Bool = { true }
    public var openFile: ((String, Int?, Int?) throws -> Void)?
    public var openBrowser: ((URL) throws -> Void)?
    public var runCommand: ((String) -> Void)?
    public var openConversation: ((SessionId, ProjectId?, AgentAssistantCitation?) async throws -> Void)?
    public var pullRequestPreview: ((URL) async throws -> GitPullRequestPreview)?
    public var repositoryOrigin: (() async throws -> String?)?
    public var workspaceDescription: (() -> String?)?
    public var loadFiles: (() async throws -> [String])?
    public var remoteImages: () -> RemoteImagePolicy = { AgentSettings().remoteImages }

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
    private var preview: AgentConversationMediaWindow?
    private var metadataTask: Task<Void, Never>?
    private var metadataLoaded = false

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
    func refreshProjectMetadata() {
        guard !metadataLoaded, metadataTask == nil, let fetch = services.repositoryOrigin else { return }
        metadataTask = Task { [weak self] in
            guard let self else { return }
            defer { self.metadataTask = nil }
            do {
                let origin = try await fetch()
                try Task.checkCancellation()
                self.surface?.linkServices.pullRequestHosts = AgentPullRequestLink.hosts(origin: origin)
                self.metadataLoaded = true
            } catch { /* A disconnected host may retry on the next snapshot. */ }
        }
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
        try await AgentConversationFileActions.writeProjectFile(relativePath, contents: contents, cwd: cwd, scope: scope(), read: reader())
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
        let next = try AgentConversationMediaWindow(resource: loaded.resource, name: (relative as NSString).lastPathComponent)
        preview?.close(); preview = next; next.showWindow(nil)
    }
    func openConversation(_ target: SessionId, project: ProjectId?, citation: AgentAssistantCitation?) async throws {
        guard let open = services.openConversation else { throw ModelError("Conversation navigation is unavailable in this application.") }
        try await open(target, project, citation)
    }
}
