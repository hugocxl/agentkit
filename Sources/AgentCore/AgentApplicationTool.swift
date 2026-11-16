import Foundation

/// A named application operation exposed to the model as a JSON Schema function.
public struct AgentToolDefinition: Sendable, Hashable, Codable {
    public var name: String
    public var description: String
    public var inputSchema: AgentJSONValue
    public init(name: String, description: String, inputSchema: AgentJSONValue) {
        self.name = name; self.description = description; self.inputSchema = inputSchema
    }
}

/// One invocation of a registered application tool.
public struct AgentToolCall: Sendable, Hashable {
    public var id: String
    public var name: String
    public var arguments: AgentJSONValue
    public init(id: String, name: String, arguments: AgentJSONValue) {
        self.id = id; self.name = name; self.arguments = arguments
    }
}

/// Text and optional images returned to both the model and the conversation UI.
public struct AgentToolResult: Sendable, Hashable {
    public var text: String
    public var images: [AgentChatAttachment]
    public var isError: Bool
    public init(text: String, images: [AgentChatAttachment] = [], isError: Bool = false) {
        self.text = text; self.images = images; self.isError = isError
    }
    public static func failure(_ message: String) -> Self { Self(text: message, isError: true) }
}
