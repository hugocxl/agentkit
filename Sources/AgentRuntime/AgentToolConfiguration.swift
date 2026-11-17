import AgentCore
import Foundation

/// Registers the host application's operations once for both Claude and Codex.
/// Handlers run asynchronously and must honor cancellation before committing an edit.
/// Mutations execute in order; explicitly independent reads may bypass them.
/// Duplicate call IDs reuse their result within a provider process.
public struct AgentToolConfiguration: Sendable {
    public enum Access: Sendable {
        /// Application edits go through registered handlers. Claude's built-in tools
        /// are disabled; Codex runs read-only, with shell execution disabled and no approvals.
        /// This does not sandbox the host's own tool handlers.
        case applicationOnly
        /// Also allow the provider's normal tools, subject to conversation access settings.
        case providerTools
    }
    public var definitions: [AgentToolDefinition]
    public var access: Access
    /// Only snapshot reads and cancellation/status operations belong here.
    public var concurrentTools: Set<String>
    /// Bounds a host invocation, not background work it explicitly schedules.
    public var executionTimeout: TimeInterval
    public var handle: @Sendable (AgentToolCall) async -> AgentToolResult
    public init(_ definitions: [AgentToolDefinition], access: Access = .applicationOnly,
                concurrentTools: Set<String> = [], executionTimeout: TimeInterval = 30,
                handle: @escaping @Sendable (AgentToolCall) async -> AgentToolResult) {
        self.definitions = definitions; self.access = access; self.handle = handle
        self.concurrentTools = concurrentTools; self.executionTimeout = executionTimeout
    }
    func validate() throws {
        guard executionTimeout.isFinite, executionTimeout > 0,
              concurrentTools.isSubset(of: Set(definitions.map(\.name))) else {
            throw ModelError("Tool deadlines must be positive and independent tools must be registered.")
        }
        guard Set(definitions.map(\.name)).count == definitions.count else {
            throw ModelError("Application tool names must be unique.")
        }
        for tool in definitions {
            guard !tool.name.isEmpty, tool.name.utf8.count <= 64,
                  tool.name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }),
                  tool.inputSchema.object != nil, tool.inputSchema["type"]?.string == "object" else {
                throw ModelError("Application tools need a function name and an object JSON Schema.")
            }
        }
    }
    var applicationOnly: Bool { access == .applicationOnly }
    var codexDefinitions: [[String: Any]] {
        definitions.map { ["type": "function", "name": $0.name, "description": $0.description,
                           "inputSchema": $0.inputSchema.foundationValue] }
    }
}

extension AgentJSONValue {
    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.foundationValue)
        case .object(let value): return value.mapValues(\.foundationValue)
        }
    }
    init(foundation value: Any) throws {
        self = try Self.decode(JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
    }
}
