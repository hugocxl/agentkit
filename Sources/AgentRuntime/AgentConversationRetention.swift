import AgentCore
import Foundation

/// How long a backend keeps conversations that are closed: their panes closed, archived from
/// history, or left behind by a clear in place. The host chooses; AgentKit has no settings.
///
/// Open conversations are never deleted. Conversations saved by versions before 1.4 have no
/// recorded close time; the first run of this version takes their file's last modification
/// date as it, which is what the earlier implicit 30-day rule measured, and saves it. With
/// the default, `.keepClosed`, nothing is deleted except on an explicit, confirmed delete.
public enum AgentConversationRetention: Sendable, Equatable {
    /// Keeps closed conversations until the user deletes them. The default.
    case keepClosed
    /// Deletes a closed conversation, with everything stored only for it, at the first start
    /// after it has been closed for longer than the interval.
    case deleteClosed(after: TimeInterval)

    /// When a conversation closed at `closedAt` is deleted, or nil when it is kept.
    public func expiry(closedAt: Date) -> Date? {
        guard case .deleteClosed(let interval) = self else { return nil }
        return closedAt.addingTimeInterval(interval)
    }
}
