import Foundation
enum AgentValidation {
    static func hasNul(_ text: String) -> Bool { text.utf8.contains(0) }

    static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func hasControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    static func message(_ text: String, limit: Int) throws(ErrorCode) {
        if isBlank(text) || text.utf8.count > limit || hasNul(text) { throw .badRequest }
    }

    static func environment(_ environment: [String: String]) throws(ErrorCode) {
        guard environment.count <= AgentLimits.maxEnvironmentVariables else { throw .badRequest }
        var total = 0
        for (key, value) in environment {
            if key.isEmpty || key.contains("=") || hasNul(key) || hasNul(value) { throw .badRequest }
            total += key.utf8.count + value.utf8.count
        }
        if total > AgentLimits.maxEnvironmentBytes { throw .badRequest }
    }
}
