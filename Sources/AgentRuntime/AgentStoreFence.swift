import Foundation

/// Keeps writes to a store from outliving its ownership: once closed, none starts, and
/// closing returns only after those under way end.
final class AgentStoreFence: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private let writes = DispatchGroup()

    /// Runs `body` unless the store has been handed over; `false` when it has.
    @discardableResult
    func write(_ body: () throws -> Void) rethrows -> Bool {
        let admitted = lock.withLock { () -> Bool in
            guard !closed else { return false }
            writes.enter()
            return true
        }
        guard admitted else { return false }
        defer { writes.leave() }
        try body()
        return true
    }

    /// Stops later writes, then waits for those under way.
    func close() {
        lock.withLock { closed = true }
        writes.wait()
    }
}
