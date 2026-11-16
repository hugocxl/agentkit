import OSLog

enum AgentLog {
    static let logger = Logger(subsystem: "AgentKit", category: "Runtime")
    static func error(_ message: String) { logger.error("\(message, privacy: .public)") }
}
