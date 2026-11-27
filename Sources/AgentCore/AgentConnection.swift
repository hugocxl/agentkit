import Foundation

/// A revision notification. Consumers fetch a snapshot or delta after receiving it.
public struct AgentConversationChange: Sendable, Equatable {
    public var session: SessionId
    public var revision: UInt64
    public init(session: SessionId, revision: UInt64) {
        self.session = session; self.revision = revision
    }
}

/// What a conversation tells someone whose backend predates a service. A host that
/// updates its own servers names them, as in "Update Tab on it, then restart it."
public struct AgentBackendAdvice: Sendable, Equatable {
    /// Follows "This server can't …" for a service the backend lacks.
    public var restart: String
    /// Follows "This server can't …" for a composer action, before trying it again.
    public var update: String
    /// Follows an action the connected backend does not support; the draft is kept.
    public var reconnect: String
    /// Why a conversation could not be cleared in place; it is unchanged.
    public var clear: String

    public init(restart: String = "Update or restart the conversation backend.",
                update: String = "Update the conversation backend first.",
                reconnect: String = "Update the conversation backend, then reconnect.",
                clear: String = "Update the conversation backend to clear a conversation in place.") {
        self.restart = restart; self.update = update; self.reconnect = reconnect; self.clear = clear
    }

    /// "This server can't `service`.", followed by how to get it.
    public func cannot(_ service: String) -> String { "This server can't \(service). \(restart)" }
}

/// The boundary between a conversation surface and its owner, local or remote.
/// Each observer receives its own stream; changes may coalesce because revisions
/// identify authoritative state rather than individual text deltas.
public struct AgentConnection: Sendable {
    public let session: SessionId
    public let project: ProjectId
    public let provider: AgentChatProvider
    /// Which configured provider of `provider`'s kind to run, when not its built-in one.
    public var providerID: String?
    public var capabilities: AgentCapabilities = .all
    /// The local working folder, when the backend runs on this computer.
    public var workingDirectory: URL?
    /// Optional per-conversation draft storage owned by the embedding application. The
    /// conversation's stash of set-aside drafts is kept beside it, in a folder with the
    /// same name and the `stash` extension.
    public var draftURL: URL?
    /// What to say when the backend predates a service.
    public var backendAdvice = AgentBackendAdvice()
    public var request: @Sendable (AgentChatRequest) async throws -> AgentChatSnapshot
    public var observe: @Sendable () -> AsyncStream<AgentConversationChange>
    public var conversation: (@Sendable (AgentConversationRequest) async throws -> AgentConversationReply)?
    public var attachment: (@Sendable (AgentAttachmentRequest) async throws -> AgentAttachmentReply)?
    public var checkpoint: (@Sendable (AgentCheckpointRequest) async throws -> AgentCheckpointReply)?
    public var files: (@Sendable (FilesRequest) async throws -> FilesReply)?
    public var models: (@Sendable (AgentChatProvider, Bool) async throws -> [AgentModelDescriptor])?
    /// Lists models for a specific configured provider ID; falls back to `models` when nil.
    public var modelsForProvider: (@Sendable (AgentChatProvider, String?, Bool) async throws -> [AgentModelDescriptor])?
    /// A configured provider's models with where they came from: a `saved` reply is
    /// returned at once while the backend refreshes, and a forced request waits for it.
    /// Preferred over `modelsForProvider` when both are set.
    public var modelCatalog: (@Sendable (AgentModelCatalogRequest) async throws -> AgentModelCatalogReply)?
    /// Adds, configures, checks, installs and updates the backend's providers, for agent
    /// settings. With it, the conversation offers its own agent settings window unless the
    /// host supplies `openAgentSettings`.
    public var providerManagement: AgentProviderManagement?
    /// The backend's configured providers and their last health checks.
    public var providers: (@Sendable () async throws -> AgentProvidersState)?
    /// Subscription usage limits for signed-in providers.
    public var usageLimits: (@Sendable (AgentUsageLimitsRequest) async throws -> AgentUsageLimitsReply)?
    public var history: (@Sendable () async throws -> AgentHistoryReply)?
    public var importHistory: (@Sendable (AgentHistoryEntry, SessionId) async throws -> AgentChatSnapshot)?
    public var composerContext: (@Sendable (AgentChatProvider) async throws -> AgentComposerContextReply)?
    /// Kept conversations: archive, reopen and confirmed permanent deletion.
    public var library: (@Sendable (AgentConversationLibraryRequest) async throws -> AgentConversationLibraryReply)?

    /// Creates a connection. Supply optional services only when the backend supports them.
    public init(session: SessionId = SessionId(), project: ProjectId, provider: AgentChatProvider,
                request: @escaping @Sendable (AgentChatRequest) async throws -> AgentChatSnapshot,
                observe: @escaping @Sendable () -> AsyncStream<AgentConversationChange>) {
        self.session = session; self.project = project; self.provider = provider
        self.request = request; self.observe = observe
    }
}
