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
    let sessions: AgentSessions
    public let providers: AgentProviderStore
    private let usageLimitsService: AgentUsageLimitsService
    private let composer: AgentComposerContextService
    let models: AgentModelCatalogService
    private let historyStore: AgentHistory
    /// Reads provider history synchronously; replaced in tests to see where it runs.
    var listHistory: @Sendable (String, Set<String>) -> AgentHistoryReply
    private let titles: AgentTitles
    private let projectDirectory: @Sendable (ProjectId) throws -> URL
    private let observations = AgentChangeBroadcaster()
    private let ownership: FileLock?
    /// Model and command discovery providers, which no conversation owns.
    let discoveries = AgentProcessTracker()
    private let lifecycle = NSLock()
    private var didShutdown = false
    /// Left once the first shutdown has finished, for any other to wait on.
    private let shutDown = DispatchGroup()
    /// Tests learn here that a shutdown was admitted, before it stops anything.
    var shutdownAdmitted: (@Sendable () -> Void)?
    private let applicationToolsOnly: Bool

    /// Configure callbacks before serving requests. They run in order on a queue of their
    /// own, never the conversations', so one may call back into the service, even to shut it
    /// down; there `shutdown()` returns at once when another shutdown already runs, as that
    /// one waits for it. Called from elsewhere, `shutdown()` and `publishActivity()` return
    /// once the callbacks already queued have run.
    public var activityChanged: @Sendable (AgentChatSnapshot, String) -> Void {
        get { sessions.activityChanged }
        set { sessions.activityChanged = newValue }
    }
    public var changed: @Sendable (SessionId, UInt64) -> Void = { _, _ in }
    /// Told once a conversation was permanently deleted, by a confirmed delete or the
    /// retention rule, so the host can drop what it keeps for it, such as its draft.
    public var conversationDeleted: @Sendable (SessionId) -> Void = { _ in }
    /// Rejects new conversations in folders the host is removing or locking.
    public var checkDirectory: @Sendable (String) throws -> Void {
        get { sessions.checkDirectory }
        set { sessions.checkDirectory = newValue }
    }

    /// `storageDirectory` is exclusively locked until shutdown; another owner fails
    /// with `FileLock.Failure.held`, and any other lock failure is thrown. A host that
    /// already owns the store exclusively, as a server holding its own profile lock,
    /// passes `hostOwnsStore`: a lock it can't make, as in a read-only store, is then
    /// logged and the store served. Pass an existing
    /// conversation store directly to retain its transcripts, queues and resources.
    /// `retention` says how long closed conversations are kept; see `AgentConversationRetention`.
    public convenience init(storageDirectory: URL, modelCacheDirectory: URL? = nil,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            executables: [AgentChatProvider: URL] = [:], environment: [String: String] = [:],
                            tools: AgentToolConfiguration? = nil, hostOwnsStore: Bool = false,
                            retention: AgentConversationRetention = .keepClosed,
                            projectDirectory: @escaping @Sendable (ProjectId) throws -> URL,
                            launchContext: @escaping @Sendable (SessionId, ProjectId) -> AgentLaunchContext = { _, _ in .init() }) throws {
        try self.init(storageDirectory: storageDirectory, modelCacheDirectory: modelCacheDirectory, home: home,
                      executables: executables, environment: environment, tools: tools, hostOwnsStore: hostOwnsStore,
                      retention: retention, checkpoints: AgentCheckpointStore(), projectDirectory: projectDirectory, launchContext: launchContext)
    }

    /// `checkpoints` takes and removes the store's checkpoints; tests stand in another Git.
    init(storageDirectory: URL, modelCacheDirectory: URL? = nil,
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         executables: [AgentChatProvider: URL] = [:], environment: [String: String] = [:],
         tools: AgentToolConfiguration? = nil, hostOwnsStore: Bool = false,
         retention: AgentConversationRetention = .keepClosed, now: @escaping @Sendable () -> Date = { Date() },
         checkpoints: AgentCheckpointStore,
         projectDirectory: @escaping @Sendable (ProjectId) throws -> URL,
         launchContext: @escaping @Sendable (SessionId, ProjectId) -> AgentLaunchContext = { _, _ in .init() }) throws {
        try tools?.validate()
        self.applicationToolsOnly = tools?.applicationOnly == true
        self.projectDirectory = projectDirectory
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        do {
            ownership = try FileLock.tryLock(storageDirectory.appendingPathComponent("runtime.lock"))
        } catch let failure as FileLock.Failure {
            throw failure
        } catch where hostOwnsStore {
            AgentLog.error("Conversations in \(storageDirectory.path) run without exclusive ownership: \(error.localizedDescription)")
            ownership = nil
        }
        let providerEnvironment = AgentProcess.environment().merging(environment) { _, value in value }
        let providerStore = AgentProviderStore(url: storageDirectory.appendingPathComponent("agent-providers.json"),
                                               environment: { AgentProcess.environment().merging(environment) { _, value in value } })
        self.providers = providerStore
        // Hosts without provider settings keep reading the built-in Claude and Codex accounts.
        let usageLimitsService = AgentUsageLimitsService(providers: {
            let configured = providerStore.settings.providers
            return configured.isEmpty ? [.builtIn(.claude), .builtIn(.codex)] : configured
        })
        self.usageLimitsService = usageLimitsService
        let discoveries = discoveries
        composer = AgentComposerContextService(home: home, environment: providerEnvironment,
            discoverProvider: { provider, directory in
                // Version managers add folders after launch; discovery searches them as a new run does.
                let current = AgentProcess.environment().merging(environment) { _, value in value }
                return await AgentCommandDiscovery.discover(provider: provider, directory: directory,
                    environment: current, executable: executables[provider], processes: discoveries)
            }, projectDirectory: projectDirectory)
        let modelService = AgentModelCatalogService(home: home, executables: executables, environment: providerEnvironment,
            cacheDirectory: modelCacheDirectory ?? storageDirectory.appendingPathComponent("models"), processes: discoveries,
            providers: { providerStore.provider($0, kind: $1) },
            projectDirectory: projectDirectory)
        models = modelService
        providerStore.onChange = {
            Task {
                await modelService.invalidate()
                await usageLimitsService.invalidate()
            }
        }
        historyStore = AgentHistory(home: home, environment: providerEnvironment)
        let store = historyStore
        // Each added Claude Code and Codex provider's own folder, or each kind's default one.
        listHistory = { directory, excluding in
            let settings = providerStore.settings
            return AgentHistory.sources(settings).isEmpty ? store.list(directory: directory, excluding: excluding)
                : store.list(settings, directory: directory, excluding: excluding)
        }
        titles = AgentTitles { id, kind in store.of(id, kind: kind, settings: providerStore.settings) }
        // Encoded before the store opens, which starts recovering its checkpoints: a failure
        // here must leave nothing running.
        let toolSignature = try tools.map { tools in
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return String(decoding: try encoder.encode(tools.definitions.sorted { $0.name < $1.name }), as: UTF8.self)
        }
        sessions = try AgentSessions(root: storageDirectory, projectDirectory: { try projectDirectory($0).path },
            retention: retention, now: now, checkpoints: checkpoints, factory: { provider, directory, resume, callback -> any AgentSessionRuntime in
                provider.spec.wire == .acp
                    ? AcpAgentRuntime(provider: provider, directory: directory, resumeSession: resume, onEvent: callback)
                    : AgentRuntime(provider: provider, directory: directory, resumeSession: resume,
                                   executable: executables[provider], tools: tools, onEvent: callback)
            })
        sessions.providers = { providerStore.provider($0, kind: $1) }
        titles.onChange = { [weak sessions] in sessions?.publishActivity() }
        if let toolSignature { sessions.applicationToolSignature = toolSignature }
        sessions.otherProvidersMayRun = { [discoveries] in discoveries.mayRun(in: $0) }
        sessions.otherProviderProcesses = { [discoveries] in discoveries.processIDs() }
        sessions.capturesCheckpoints = !applicationToolsOnly
        sessions.defaultAccess = applicationToolsOnly ? .ask : .fullAccess
        sessions.launchContext = { session, project in
            let context = launchContext(session, project)
            return AgentLaunch(environment: environment.merging(context.environment) { _, value in value },
                               path: context.executableDirectory, instructions: context.instructions)
        }
        let composer = self.composer
        sessions.composerCatalog = { try await composer.catalog($0) }
        sessions.conversationDeleted = { [weak self] session in self?.conversationDeleted(session) }
        sessions.changed = { [weak self] session, revision in
            guard let self else { return }
            self.observations.publish(.init(session: session, revision: revision))
            self.changed(session, revision)
        }
        sessions.resumeWorkEndedByRestart()
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
        if applicationToolsOnly {
            switch request {
            case .revert, .rewind(_, _, _, _, true, _): throw ModelError("Use the application's undo tools to revert an edit.")
            case .retryCheckpoint: throw ServiceError(.unsupported, "Checkpoints are unavailable for application tools.")
            default: break
            }
        }
        return try await sessions.conversation(request)
    }
    /// Lists, archives, reopens and permanently deletes kept conversations.
    public func library(_ request: AgentConversationLibraryRequest) async throws -> AgentConversationLibraryReply {
        try await sessions.library(request)
    }
    public func attachment(_ request: AgentAttachmentRequest) async throws -> AgentAttachmentReply { try await sessions.attachment(request) }
    public func checkpoint(_ request: AgentCheckpointRequest) async throws -> AgentCheckpointReply {
        guard !applicationToolsOnly else { throw ServiceError(.unsupported, "Checkpoints are unavailable for application tools.") }
        return try await sessions.checkpoint(request)
    }
    public func modelCatalog(_ request: AgentModelCatalogRequest) async throws -> AgentModelCatalogReply { try await models.handle(request) }
    public func usageLimits(_ request: AgentUsageLimitsRequest = .init()) async -> AgentUsageLimitsReply {
        await usageLimitsService.handle(request)
    }
    public func composerContext(_ request: AgentComposerContextRequest) async throws -> AgentComposerContextReply {
        guard !applicationToolsOnly else { throw ServiceError(.unsupported, "Provider commands are unavailable for application tools.") }
        return try await composer.catalog(request)
    }
    public func history(_ request: AgentHistoryRequest) async throws -> AgentHistoryReply {
        guard !applicationToolsOnly else { throw ServiceError(.unsupported, "Provider history is unavailable for application tools.") }
        let directory = try projectDirectory(request.project).path
        let open = sessions.openProviderSessions(), list = listHistory
        return try await runBlocking { list(directory, open) }
    }
    public func importHistory(_ request: AgentHistoryImport) async throws -> AgentChatSnapshot {
        guard !applicationToolsOnly else { throw ServiceError(.unsupported, "Provider history is unavailable for application tools.") }
        let settings = providers.settings
        var request = request
        request.providerID = AgentHistory.source(request.providerID, kind: request.provider, settings: settings)?.id
        let history = historyStore.of(request.providerID, kind: request.provider, settings: settings)
        let resolved = request
        return try await sessions.importHistory(resolved) { directory in
            try history.transcript(provider: resolved.provider, session: resolved.providerSession, directory: directory)
        }
    }
    /// Reads provider metadata; call off the main or request-handling queue.
    public func sessionTitle(provider: AgentChatProvider, session: String, directory: String) -> String? {
        historyStore.sessionTitle(provider: provider, session: session, directory: directory)
    }
    /// Returns the cached provider title and refreshes it asynchronously after turns.
    public func activityTitle(for snapshot: AgentChatSnapshot, directory: String) -> String? { titles.title(for: snapshot, directory: directory) }
    public func publishActivity() { sessions.publishActivity() }
    /// How long shutdown waits for checkpoints being taken, or `nil` until they end; tests shorten it.
    var checkpointDrain: TimeInterval? {
        get { sessions.checkpointDrain }
        set { sessions.checkpointDrain = newValue }
    }
    public var hasSessions: Bool { sessions.hasSessions }
    public func close(project: ProjectId, directory: String? = nil) { sessions.close(project: project, directory: directory) }
    /// Atomically refuses new work only if no live conversation needs the runtime.
    public func tryRefuseIfIdle() -> Bool { sessions.tryRefuseIfIdle() }
    public func refuseNewRequests() { sessions.refuseNewRequests() }

    /// Stops processes, waits for checkpoints being taken and reverts under way, flushes
    /// persistence, finishes observers, and releases storage, so the store can be opened
    /// again once it returns. Call off the main thread; shutdown can wait for process, Git
    /// and disk operations, though never for a Swift task worker.
    public func shutdown() {
        let first = lifecycle.withLock { () -> Bool in
            guard !didShutdown else { return false }
            didShutdown = true
            shutDown.enter()
            return true
        }
        // Another caller shuts it down: wait until it has, unless this is a callback, which
        // that shutdown waits for in turn.
        guard first else {
            guard !sessions.onCallbackQueue else { return }
            shutDown.wait()
            sessions.drainCallbacks()
            return
        }
        defer { shutDown.leave() }
        shutdownAdmitted?()
        let discoveries = discoveries
        let stopped = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: stopped) { discoveries.shutdown() }
        sessions.shutdown()
        stopped.wait()
        observations.finish()
        // A model catalog read after this can't overwrite a newer one the next owner saves.
        models.cacheWrites.close()
        // A checkpoint still being taken holds the store until it is written.
        let ownership = ownership
        sessions.releaseStore { ownership?.unlock() }
    }
    deinit { shutdown() }
}
