import Foundation

/// A conversation the backend keeps that no pane needs to show: one whose pane closed, one
/// archived from history, or the earlier conversation a clear in place left behind. It
/// keeps its identity, transcript, checkpoints, attachments and acceptance ledger.
public struct AgentSavedConversation: Codable, Hashable, Sendable, Identifiable {
    /// How the conversation came to be kept.
    public struct Origin: RawRepresentable, Codable, Hashable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
        public func encode(to encoder: Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(rawValue) }
        /// Its pane closed, or it was archived from history.
        public static let closed = Origin(rawValue: "closed")
        /// A clear in place started its pane over and kept this as the earlier conversation.
        public static let cleared = Origin(rawValue: "cleared")
    }

    public var session: SessionId
    public var project: ProjectId
    public var provider: AgentChatProvider
    /// The first message's opening words, or a generic title.
    public var title: String
    public var origin: Origin
    /// When it was closed or archived; for records from earlier versions, their last change.
    public var closedAt: Date?
    /// Messages kept in its transcript.
    public var messages: Int
    /// When the host's retention will delete it, or nil when it is kept until deleted.
    public var expiresAt: Date?

    public var id: SessionId { session }

    public init(session: SessionId, project: ProjectId, provider: AgentChatProvider, title: String, origin: Origin,
                closedAt: Date?, messages: Int, expiresAt: Date? = nil) {
        self.session = session; self.project = project; self.provider = provider; self.title = title
        self.origin = origin; self.closedAt = closedAt; self.messages = messages; self.expiresAt = expiresAt
    }
}

/// Archive, reopen and permanent deletion of a backend's kept conversations.
public enum AgentConversationLibraryRequest: Codable, Hashable, Sendable {
    /// Kept conversations, newest first; all projects when `project` is nil.
    case list(project: ProjectId?)
    /// Closes an idle conversation and keeps it for reopening. Refused while work runs.
    case archive(session: SessionId)
    /// Makes a kept conversation usable again under its original identity, with its
    /// checkpoints, attachments and acceptance ledger. Prompts whose delivery is uncertain
    /// stay paused for review.
    case reopen(session: SessionId)
    /// Permanently deletes a kept conversation and everything stored only for it.
    /// `confirmation` must be `deleteConfirmation(for:)`, which a client sends only after
    /// the user confirmed the deletion.
    case delete(session: SessionId, confirmation: String)

    public static func deleteConfirmation(for session: SessionId) -> String { "delete " + session.description }

    public func validate() throws(ErrorCode) {
        if case .delete(let session, let confirmation) = self, confirmation != Self.deleteConfirmation(for: session) {
            throw .badRequest
        }
    }
}

public enum AgentConversationLibraryReply: Codable, Hashable, Sendable {
    case list([AgentSavedConversation])
    case snapshot(AgentChatSnapshot)
    case deleted(SessionId)
}
