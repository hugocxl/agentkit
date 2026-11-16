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
    private let runtime: AgentRuntimeService

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
        runtime = try AgentRuntimeService(storageDirectory: storageDirectory.appendingPathComponent("conversations"),
            modelCacheDirectory: storageDirectory.appendingPathComponent("models"), executables: executables,
            environment: environment, tools: tools, projectDirectory: { URL(fileURLWithPath: try resolve($0)) },
            launchContext: { _, _ in .init(instructions: instructions) })
    }

    /// Creates a connection without starting a CLI. Sending the first prompt starts it.
    /// Reuse a session ID to reopen a saved conversation.
    public func connect(provider: AgentChatProvider, session: SessionId = SessionId()) -> AgentConnection {
        var connection = AgentConnection(session: session, project: project, provider: provider,
                                         request: { [runtime] in try await runtime.handle($0) },
                                         observe: { [runtime] in runtime.observe(session: session) })
        connection.workingDirectory = workingDirectory
        connection.draftURL = storageDirectory.appendingPathComponent("drafts/\(session).json")
        connection.conversation = { [runtime] in try await runtime.conversation($0) }
        connection.attachment = { [runtime] in try await runtime.attachment($0) }
        if !applicationToolsOnly { connection.checkpoint = { [runtime] in try await runtime.checkpoint($0) } }
        connection.files = { [files] in try await files.handle($0) }
        connection.models = { [runtime, project] provider, refresh in
            try await runtime.modelCatalog(.init(project: project, provider: provider, forceRefresh: refresh)).models
        }
        connection.history = { [runtime, project] in try await runtime.history(.init(project: project)) }
        connection.importHistory = { [runtime, project] entry, session in
            try await runtime.importHistory(.init(session: session, project: project, provider: entry.provider,
                                                 providerSession: entry.providerSession))
        }
        connection.composerContext = { [runtime, project] provider in
            try await runtime.composerContext(.init(project: project, provider: provider, forceRefresh: true))
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
        runtime.shutdown()
        ownership.unlock()
    }

    deinit { shutdown() }
}
