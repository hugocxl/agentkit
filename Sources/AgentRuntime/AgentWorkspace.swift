import Foundation
import AgentCore

/// Owns local CLI conversations for one working directory. Keep this object alive
/// while conversations run and call `shutdown()` before the host exits.
public final class AgentWorkspace: @unchecked Sendable {
    public let project: ProjectId
    public let workingDirectory: URL
    public let storageDirectory: URL
    private let applicationToolsOnly: Bool
    private let files: AgentLocalFiles
    private let ownership: FileLock
    private let lifecycle = NSLock()
    private var didShutdown = false
    private struct Identity: Codable, Equatable { var project: ProjectId; var directory: String }
    private let sessions: AgentSessions
    private let catalogs: AgentModelCatalogService
    private let historyStore: AgentHistory
    private let composer: AgentComposerContextService
    private let observations = AgentChangeBroadcaster()

    /// Creates an independent workspace. `storageDirectory` must be dedicated to
    /// this workspace; reuse it and `project` to restore saved conversations.
    /// Provider executables otherwise resolve from the user's CLI search path.
    public init(workingDirectory: URL, storageDirectory: URL,
                project: ProjectId,
                executables: [AgentChatProvider: URL] = [:],
                environment: [String: String] = [:], instructions: String? = nil,
                tools: AgentToolConfiguration? = nil) throws {
        try tools?.validate()
        self.applicationToolsOnly = tools?.applicationOnly == true
        self.project = project
        self.workingDirectory = workingDirectory.standardizedFileURL
        self.storageDirectory = storageDirectory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ModelError("The working directory does not exist.")
        }
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        ownership = try FileLock.tryLock(storageDirectory.appendingPathComponent("workspace.lock"))
        let identityURL = storageDirectory.appendingPathComponent("workspace.json")
        let identity = Identity(project: project, directory: workingDirectory.resolvingSymlinksInPath().standardizedFileURL.path)
        if FileManager.default.fileExists(atPath: identityURL.path) {
            let saved = try JSONDecoder().decode(Identity.self, from: Data(contentsOf: identityURL))
            guard saved == identity else { throw ModelError("This storage directory belongs to another workspace.") }
        } else {
            try AtomicFile.write(JSONEncoder().encode(identity), to: identityURL)
        }
        files = try AgentLocalFiles(directory: self.workingDirectory, project: project)
        let directory = self.workingDirectory
        let resolve: @Sendable (ProjectId) throws -> String = { id in
            guard id == project else { throw ServiceError(.unknownProject, "This conversation belongs to another workspace.") }
            return directory.path
        }
        let observations = self.observations
        sessions = try AgentSessions(root: storageDirectory.appendingPathComponent("conversations"),
                                     projectDirectory: resolve,
                                     changed: { observations.publish(.init(session: $0, revision: $1)) },
                                     factory: { provider, directory, resume, callback in
            AgentRuntime(provider: provider, directory: directory, resumeSession: resume,
                         executable: executables[provider], tools: tools, onEvent: callback)
        })
        sessions.capturesCheckpoints = !applicationToolsOnly
        sessions.defaultAccess = applicationToolsOnly ? .ask : .fullAccess
        sessions.launchContext = { _, _ in AgentLaunch(environment: environment, instructions: instructions) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        catalogs = AgentModelCatalogService(home: home, executables: executables,
                                           environment: AgentProcess.environment().merging(environment) { _, value in value }, cacheDirectory: storageDirectory.appendingPathComponent("models"),
                                           projectDirectory: { URL(fileURLWithPath: try resolve($0)) })
        historyStore = AgentHistory(home: home)
        composer = AgentComposerContextService(home: home, projectDirectory: { URL(fileURLWithPath: try resolve($0)) })
    }

    /// Creates a connection without starting a CLI. Sending the first prompt starts it.
    /// Reuse a session ID to reopen a saved conversation.
    public func connect(provider: AgentChatProvider, session: SessionId = SessionId()) -> AgentConnection {
        var connection = AgentConnection(session: session, project: project, provider: provider,
                                         request: { [self] request in
            if applicationToolsOnly {
                if case .setAccess = request { throw ModelError("Application tool access is controlled by the host.") }
                if case .setPlan = request { throw ModelError("Plan mode is unavailable for application tools.") }
            }
            return try await sessions.handle(request)
        },
                                         observe: { [observations] in observations.stream(session: session) })
        connection.workingDirectory = workingDirectory
        connection.draftURL = storageDirectory.appendingPathComponent("drafts/\(session).json")
        connection.conversation = { [self] request in
            if applicationToolsOnly, case .revert = request { throw ModelError("Use the application's undo tools to revert an edit.") }
            return try await sessions.conversation(request)
        }
        connection.attachment = { [self] in try await sessions.attachment($0) }
        if !applicationToolsOnly { connection.checkpoint = { [self] in try await sessions.checkpoint($0) } }
        connection.files = { [files] in try await files.handle($0) }
        connection.models = { [self] provider, refresh in
            try await catalogs.handle(.init(project: project, provider: provider, forceRefresh: refresh)).models
        }
        connection.history = { [self] in
            let excluding = sessions.openProviderSessions()
            return await Task.detached { [self] in historyStore.list(directory: workingDirectory.path, excluding: excluding) }.value
        }
        connection.importHistory = { [self] entry, session in
            try await sessions.importHistory(.init(session: session, project: project, provider: entry.provider,
                                                   providerSession: entry.providerSession)) { [historyStore] directory in
                try historyStore.transcript(provider: entry.provider, session: entry.providerSession, directory: directory)
            }
        }
        connection.composerContext = { [self] provider in
            try await Task.detached { [self] in try await composer.handle(.init(project: project, provider: provider)) }.value
        }
        if applicationToolsOnly {
            connection.capabilities = [.modelSelection, .attachments, .promptQueue]
            // Provider history can contain unrestricted coding sessions with different tools.
            connection.history = nil; connection.importHistory = nil; connection.composerContext = nil
        }
        return connection
    }

    /// Interrupts running work, durably saves conversations, and finishes observers.
    /// Run off the main thread: process shutdown and the persistence flush can block.
    public func shutdown() {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard !didShutdown else { return }
        didShutdown = true
        sessions.shutdown()
        observations.finish()
        ownership.unlock()
    }

    deinit { shutdown() }
}
