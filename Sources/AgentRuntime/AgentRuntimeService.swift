import Foundation
import AgentCore

/// Host-provided context for a provider process. Conversation and fork identities
/// are managed by the runtime and cannot be overridden by the host.
public struct AgentLaunchContext: Sendable {
    public var environment: [String: String]
    public var executableDirectory: String?
    public var instructions: String?

    public init(environment: [String: String] = [:], executableDirectory: String? = nil, instructions: String? = nil) {
        self.environment = environment; self.executableDirectory = executableDirectory; self.instructions = instructions
    }
}

/// A durable, multi-project agent backend for applications and transport servers.
/// The host owns project identities, resolves their folders, and forwards the
/// change notifications over its transport. Storage uses the same conversation
/// layout as AgentWorkspace; existing records need no conversion.
public final class AgentRuntimeService: @unchecked Sendable {
    private let sessions: AgentSessions
    private let composer: AgentComposerContextService
    private let models: AgentModelCatalogService
    private let historyStore: AgentHistory
    private let titles: AgentTitles
    private let projectDirectory: @Sendable (ProjectId) throws -> URL
    private let observations = AgentChangeBroadcaster()
    private let ownership: FileLock
    private let lifecycle = NSLock()
    private var didShutdown = false
    private let applicationToolsOnly: Bool

    /// Configure callbacks before serving requests. They may run on runtime queues.
    public var activityChanged: @Sendable (AgentChatSnapshot, String) -> Void {
        get { sessions.activityChanged }
        set { sessions.activityChanged = newValue }
    }
    public var changed: @Sendable (SessionId, UInt64) -> Void = { _, _ in }
    /// Rejects new conversations in folders the host is removing or locking.
    public var checkDirectory: @Sendable (String) throws -> Void {
        get { sessions.checkDirectory }
        set { sessions.checkDirectory = newValue }
    }

    /// `storageDirectory` is exclusively locked until shutdown. Pass an existing
    /// conversation store directly to retain its transcripts, queues and resources.
    public init(storageDirectory: URL, modelCacheDirectory: URL? = nil,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                executables: [AgentChatProvider: URL] = [:], environment: [String: String] = [:],
                tools: AgentToolConfiguration? = nil,
                projectDirectory: @escaping @Sendable (ProjectId) throws -> URL,
                launchContext: @escaping @Sendable (SessionId, ProjectId) -> AgentLaunchContext = { _, _ in .init() }) throws {
        try tools?.validate()
        self.applicationToolsOnly = tools?.applicationOnly == true
        self.projectDirectory = projectDirectory
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        ownership = try FileLock.tryLock(storageDirectory.appendingPathComponent("runtime.lock"))
        let providerEnvironment = AgentProcess.environment().merging(environment) { _, value in value }
        composer = AgentComposerContextService(home: home, environment: providerEnvironment,
            discoverProvider: { provider, directory in
                await AgentCommandDiscovery.discover(provider: provider, directory: directory,
                    environment: providerEnvironment, executable: executables[provider])
            }, projectDirectory: projectDirectory)
        models = AgentModelCatalogService(home: home, executables: executables, environment: providerEnvironment,
            cacheDirectory: modelCacheDirectory ?? storageDirectory.appendingPathComponent("models"), projectDirectory: projectDirectory)
        historyStore = AgentHistory(home: home, environment: providerEnvironment)
        titles = AgentTitles(history: historyStore)
        sessions = try AgentSessions(root: storageDirectory, projectDirectory: { try projectDirectory($0).path },
            factory: { provider, directory, resume, callback in
                AgentRuntime(provider: provider, directory: directory, resumeSession: resume,
                             executable: executables[provider], tools: tools, onEvent: callback)
            })
        titles.onChange = { [weak sessions] in sessions?.publishActivity() }
        if let tools {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            sessions.applicationToolSignature = String(decoding: try encoder.encode(tools.definitions.sorted { $0.name < $1.name }), as: UTF8.self)
        }
        sessions.capturesCheckpoints = !applicationToolsOnly
        sessions.defaultAccess = applicationToolsOnly ? .ask : .fullAccess
        sessions.launchContext = { session, project in
            let context = launchContext(session, project)
            return AgentLaunch(environment: environment.merging(context.environment) { _, value in value },
                               path: context.executableDirectory, instructions: context.instructions)
        }
        let composer = self.composer
        sessions.composerCatalog = { try await composer.catalog($0) }
        sessions.changed = { [weak self] session, revision in
            guard let self else { return }
            self.observations.publish(.init(session: session, revision: revision))
            self.changed(session, revision)
        }
    }

    /// Each observer receives independent, coalesced revision notifications.
    public func observe(session: SessionId) -> AsyncStream<AgentConversationChange> { observations.stream(session: session) }
    public func handle(_ request: AgentChatRequest) async throws -> AgentChatSnapshot {
        if applicationToolsOnly {
            if case .setAccess = request { throw ModelError("Application tool access is controlled by the host.") }
            if case .setPlan = request { throw ModelError("Plan mode is unavailable for application tools.") }
        }
        return try await sessions.handle(request)
    }
    public func conversation(_ request: AgentConversationRequest) async throws -> AgentConversationReply {
        if applicationToolsOnly, case .revert = request { throw ModelError("Use the application's undo tools to revert an edit.") }
        return try await sessions.conversation(request)
    }
    public func attachment(_ request: AgentAttachmentRequest) async throws -> AgentAttachmentReply { try await sessions.attachment(request) }
    public func checkpoint(_ request: AgentCheckpointRequest) async throws -> AgentCheckpointReply {
        guard !applicationToolsOnly else { throw ServiceError(.unsupported, "Checkpoints are unavailable for application tools.") }
        return try await sessions.checkpoint(request)
    }
    public func modelCatalog(_ request: AgentModelCatalogRequest) async throws -> AgentModelCatalogReply { try await models.handle(request) }
    public func composerContext(_ request: AgentComposerContextRequest) async throws -> AgentComposerContextReply {
        guard !applicationToolsOnly else { throw ServiceError(.unsupported, "Provider commands are unavailable for application tools.") }
        return try await composer.catalog(request)
    }
    public func history(_ request: AgentHistoryRequest) async throws -> AgentHistoryReply {
        guard !applicationToolsOnly else { throw ServiceError(.unsupported, "Provider history is unavailable for application tools.") }
        let directory = try projectDirectory(request.project).path
        let open = sessions.openProviderSessions(), history = historyStore
        return try await runBlocking { history.list(directory: directory, excluding: open) }
    }
    public func importHistory(_ request: AgentHistoryImport) async throws -> AgentChatSnapshot {
        guard !applicationToolsOnly else { throw ServiceError(.unsupported, "Provider history is unavailable for application tools.") }
        return try await sessions.importHistory(request) { [historyStore] directory in
            try historyStore.transcript(provider: request.provider, session: request.providerSession, directory: directory)
        }
    }
    /// Reads provider metadata; call off the main or request-handling queue.
    public func sessionTitle(provider: AgentChatProvider, session: String, directory: String) -> String? {
        historyStore.sessionTitle(provider: provider, session: session, directory: directory)
    }
    /// Returns the cached provider title and refreshes it asynchronously after turns.
    public func activityTitle(for snapshot: AgentChatSnapshot, directory: String) -> String? { titles.title(for: snapshot, directory: directory) }
    public func publishActivity() { sessions.publishActivity() }
    public var hasSessions: Bool { sessions.hasSessions }
    public func close(project: ProjectId, directory: String? = nil) { sessions.close(project: project, directory: directory) }
    /// Atomically refuses new work only if no live conversation needs the runtime.
    public func tryRefuseIfIdle() -> Bool { sessions.tryRefuseIfIdle() }
    public func refuseNewRequests() { sessions.refuseNewRequests() }

    /// Stops processes, flushes persistence, finishes observers, and releases storage.
    /// Call off the main thread; shutdown can wait for process and disk operations.
    public func shutdown() {
        lifecycle.lock(); defer { lifecycle.unlock() }
        guard !didShutdown else { return }
        didShutdown = true
        sessions.shutdown(); observations.finish(); ownership.unlock()
    }
    deinit { shutdown() }
}
