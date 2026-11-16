import SwiftUI

/// Embeds an existing native conversation controller in SwiftUI without recreating its session.
@MainActor
public struct AgentConversationView: NSViewControllerRepresentable {
    public let controller: AgentConversationViewController
    public init(controller: AgentConversationViewController) { self.controller = controller }
    public func makeNSViewController(context: Context) -> AgentConversationViewController { controller }
    public func updateNSViewController(_ controller: AgentConversationViewController, context: Context) {}
}
