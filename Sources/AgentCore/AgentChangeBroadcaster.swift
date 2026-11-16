import Foundation

/// Per-observer buffering prevents a busy conversation from dropping another's update.
public final class AgentChangeBroadcaster: @unchecked Sendable {
    public init() {}
    private let lock = NSLock()
    private var closed = false
    private var observers: [UUID: (SessionId, AsyncStream<AgentConversationChange>.Continuation)] = [:]

    public func stream(session: SessionId) -> AsyncStream<AgentConversationChange> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.lock()
            let closed = self.closed
            if !closed { observers[id] = (session, continuation) }
            lock.unlock()
            if closed { continuation.finish() }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.observers.removeValue(forKey: id); self.lock.unlock()
            }
        }
    }

    public func publish(_ change: AgentConversationChange) {
        lock.lock()
        let continuations = observers.values.filter { $0.0 == change.session }.map(\.1)
        lock.unlock()
        for continuation in continuations { continuation.yield(change) }
    }

    public func finish() {
        lock.lock()
        closed = true
        let continuations = observers.values.map(\.1)
        observers.removeAll()
        lock.unlock()
        for continuation in continuations { continuation.finish() }
    }
}
