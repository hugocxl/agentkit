import Foundation

/// Revocable authority for one host invocation. A host must use `withCommit` at
/// its synchronous mutation boundary, including work started by the invocation.
/// Completing a tool response does not end the lease; ending its turn does.
public final class AgentToolExecutionContext: @unchecked Sendable {
    @TaskLocal public static var current: AgentToolExecutionContext?
    public let id: UUID
    public let callID: String
    public let tool: String
    private let lock = NSRecursiveLock()
    private var revoked = false
    private var committed = false
    private var handlers: [UUID: @Sendable () -> Void] = [:]

    public init(callID: String, tool: String) {
        id = UUID(); self.callID = callID; self.tool = tool
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return revoked
    }
    public var didCommit: Bool {
        lock.lock(); defer { lock.unlock() }; return committed
    }

    public func checkCancellation() throws {
        try Task.checkCancellation()
        if isCancelled { throw CancellationError() }
    }

    /// Cancellation acknowledgement and a commit cannot cross this boundary.
    /// Keep this body short: stage expensive I/O first, then publish atomically.
    /// Never suspend or call `revoke` from the body.
    public func withCommit<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard !revoked, !Task.isCancelled else { throw CancellationError() }
        let result = try body()
        committed = true
        return result
    }

    /// Registers native/background cancellation. Called immediately if revoked.
    @discardableResult
    public func onCancel(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        if revoked { lock.unlock(); handler() }
        else { handlers[token] = handler; lock.unlock() }
        return token
    }

    public func removeCancellationHandler(_ token: UUID) {
        lock.lock(); handlers.removeValue(forKey: token); lock.unlock()
    }

    /// Runtime lifecycle owners revoke all leases before ending a turn.
    public func revoke() {
        lock.lock()
        guard !revoked else { lock.unlock(); return }
        revoked = true
        let callbacks = Array(handlers.values); handlers.removeAll()
        lock.unlock()
        callbacks.forEach { $0() }
    }
}
