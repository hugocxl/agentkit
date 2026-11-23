import Foundation
/// Last explicit composer choices; optional fields retain provider defaults.
public struct AgentComposerPreferences: Codable, Equatable, Sendable {
    public var provider: AgentChatProvider
    /// Which of the backend's providers of `provider`'s kind; nil is its built-in one.
    public var providerID: String?
    public var model: String?
    public var effort: AgentReasoningEffort?
    public var access: AgentAccessMode?
    public init(provider: AgentChatProvider, providerID: String? = nil, model: String?, effort: AgentReasoningEffort?, access: AgentAccessMode?) {
        self.provider = provider; self.providerID = providerID; self.model = model; self.effort = effort; self.access = access
    }
}
