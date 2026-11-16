import Foundation
/// Last explicit composer choices; optional fields retain provider defaults.
public struct AgentComposerPreferences: Codable, Equatable, Sendable {
    public var provider: AgentChatProvider
    public var model: String?
    public var effort: AgentReasoningEffort?
    public var access: AgentAccessMode?
    public init(provider: AgentChatProvider, model: String?, effort: AgentReasoningEffort?, access: AgentAccessMode?) {
        self.provider = provider; self.model = model; self.effort = effort; self.access = access
    }
}
