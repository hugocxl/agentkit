import Foundation
import OSLog

/// Where AgentKit's runtime errors go besides unified logging, such as a host's
/// own log file.
public enum AgentRuntimeLog {
    private static let handler = OSAllocatedUnfairLock<(@Sendable (String) -> Void)?>(initialState: nil)

    /// Also sends every later runtime error to `forward`, which may run on any
    /// thread; nil stops forwarding.
    public static func setErrorHandler(_ forward: (@Sendable (String) -> Void)?) {
        handler.withLock { $0 = forward }
    }

    static func error(_ message: String) {
        handler.withLock { $0 }?(message)
    }
}

enum AgentLog {
    static let logger = Logger(subsystem: "AgentKit", category: "Runtime")
    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        AgentRuntimeLog.error(message)
    }
}
