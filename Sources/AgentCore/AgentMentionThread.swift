/// A conversation the host makes available as composer context.
public struct AgentMentionThread: Sendable {
    public var id: String
    public var title: String
    public var context: String
    public init(id: String, title: String, context: String) {
        self.id = id; self.title = title; self.context = context
    }
}
