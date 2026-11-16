import Foundation

/// A revision notification. Consumers fetch a snapshot or delta after receiving it.
public struct AgentConversationChange: Sendable, Equatable {
    public var session: SessionId
    public var revision: UInt64
    public init(session: SessionId, revision: UInt64) {
        self.session = session; self.revision = revision
    }
}

/// The boundary between a conversation surface and its owner, local or remote.
/// Each observer receives its own stream; changes may coalesce because revisions
/// identify authoritative state rather than individual text deltas.
public struct AgentConnection: Sendable {
    public let session: SessionId
    public let project: ProjectId
    public let provider: AgentChatProvider
    public var capabilities: AgentCapabilities = .all
    /// The local working folder, when the backend runs on this computer.
    public var workingDirectory: URL?
    /// Optional per-conversation draft storage owned by the embedding application.
    public var draftURL: URL?
    public var request: @Sendable (AgentChatRequest) async throws -> AgentChatSnapshot
    public var observe: @Sendable () -> AsyncStream<AgentConversationChange>
    public var conversation: (@Sendable (AgentConversationRequest) async throws -> AgentConversationReply)?
    public var attachment: (@Sendable (AgentAttachmentRequest) async throws -> AgentAttachmentReply)?
    public var checkpoint: (@Sendable (AgentCheckpointRequest) async throws -> AgentCheckpointReply)?
    public var files: (@Sendable (FilesRequest) async throws -> FilesReply)?
    public var models: (@Sendable (AgentChatProvider, Bool) async throws -> [AgentModelDescriptor])?
    public var history: (@Sendable () async throws -> AgentHistoryReply)?
    public var importHistory: (@Sendable (AgentHistoryEntry, SessionId) async throws -> AgentChatSnapshot)?
    public var composerContext: (@Sendable (AgentChatProvider) async throws -> AgentComposerContextReply)?

    /// Creates a connection. Supply optional services only when the backend supports them.
    public init(session: SessionId = SessionId(), project: ProjectId, provider: AgentChatProvider,
                request: @escaping @Sendable (AgentChatRequest) async throws -> AgentChatSnapshot,
                observe: @escaping @Sendable () -> AsyncStream<AgentConversationChange>) {
        self.session = session; self.project = project; self.provider = provider
        self.request = request; self.observe = observe
    }
}
