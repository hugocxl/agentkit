import Foundation

/// One answer a provider offered for a pending request, carried to the card and back
/// unchanged, so the button the user presses is the decision the provider receives.
public struct AgentApprovalDecision: Codable, Hashable, Sendable, Identifiable {
    /// What a decision does. Unknown kinds from newer backends round-trip and show as their label.
    public struct Kind: RawRepresentable, Codable, Hashable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
        public func encode(to encoder: Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(rawValue) }
        /// Allows this request only.
        public static let allowOnce = Kind(rawValue: "allowOnce")
        /// Allows this request and matching ones until the provider session ends.
        public static let allowSession = Kind(rawValue: "allowSession")
        /// Allows this request and adds a lasting provider rule, such as a command prefix.
        public static let allowAlways = Kind(rawValue: "allowAlways")
        /// Refuses this request; the agent carries on without it.
        public static let decline = Kind(rawValue: "decline")
        /// Refuses this request and ends the provider's turn or form.
        public static let cancel = Kind(rawValue: "cancel")
        /// Sends the answers of the form attached to the request.
        public static let submit = Kind(rawValue: "submit")

        /// Decisions that let the request go ahead.
        public var allows: Bool { self == .allowOnce || self == .allowSession || self == .allowAlways || self == .submit }
    }

    /// The provider's own token for the decision, such as Codex's `acceptForSession`.
    public var id: String
    public var kind: Kind
    public var label: String
    /// What choosing it does, in one sentence for the button's help.
    public var consequence: String?

    public init(id: String, kind: Kind, label: String, consequence: String? = nil) {
        self.id = id; self.kind = kind; self.label = label; self.consequence = consequence
    }
}

/// Who asked: the conversation's own agent, or an agent it started.
public struct AgentRequestOrigin: Codable, Hashable, Sendable {
    /// The provider thread the request came from, as Codex names it.
    public var threadID: String?
    /// The child agent's provider identity, such as Claude's `agent_id` or a Codex child thread.
    public var agentID: String?
    /// The transcript tool row that started the child agent, when known.
    public var toolUseID: String?
    /// How to name the child agent to the user, when known.
    public var name: String?

    public init(threadID: String? = nil, agentID: String? = nil, toolUseID: String? = nil, name: String? = nil) {
        self.threadID = threadID; self.agentID = agentID; self.toolUseID = toolUseID; self.name = name
    }

    /// Whether a child agent, not the conversation's agent, asked.
    public var isChild: Bool { agentID != nil || toolUseID != nil }
}

/// A provider request shown as a native card: what it asks for, the decisions the provider
/// offered and, once settled, what happened. Approval items from backends that predate it
/// have none and keep plain Allow and Deny.
public struct AgentApprovalRequest: Codable, Hashable, Sendable {
    /// How the request was settled.
    public struct Outcome: RawRepresentable, Codable, Hashable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
        public func encode(to encoder: Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(rawValue) }
        /// The user chose `chosen`, and the provider was told.
        public static let decided = Outcome(rawValue: "decided")
        /// The conversation's access mode answered it with `chosen`.
        public static let automatic = Outcome(rawValue: "automatic")
        /// The provider settled it elsewhere, as another client or the provider itself.
        public static let resolvedElsewhere = Outcome(rawValue: "resolvedElsewhere")
        /// The agent that asked ended first; nothing was sent.
        public static let expired = Outcome(rawValue: "expired")
        /// The turn or provider ended first; nothing was sent.
        public static let ended = Outcome(rawValue: "ended")
    }

    /// The provider method, such as `item/permissions/requestApproval`.
    public var method: String?
    /// The provider's request ID as it was sent: a string or a number.
    public var providerRequestID: AgentJSONValue?
    /// What is being approved, such as the command line or the MCP server's message.
    public var summary: String?
    /// How far an allowance reaches, such as "This turn" or "MCP server github".
    public var scope: String?
    /// What the request asks for, a line each, such as paths and network access.
    public var requested: [String]?
    /// The decisions the provider offered, in its order.
    public var decisions: [AgentApprovalDecision]
    public var origin: AgentRequestOrigin?
    /// The decision sent, once one was.
    public var chosen: String?
    public var outcome: Outcome?

    public init(method: String? = nil, providerRequestID: AgentJSONValue? = nil, summary: String? = nil, scope: String? = nil,
                requested: [String]? = nil, decisions: [AgentApprovalDecision], origin: AgentRequestOrigin? = nil,
                chosen: String? = nil, outcome: Outcome? = nil) {
        self.method = method; self.providerRequestID = providerRequestID; self.summary = summary; self.scope = scope
        self.requested = requested; self.decisions = decisions; self.origin = origin; self.chosen = chosen; self.outcome = outcome
    }

    public func decision(_ id: String) -> AgentApprovalDecision? { decisions.first { $0.id == id } }

    /// The one decision of `kind`, when the provider offered exactly one; shortcuts bind only to it.
    public func only(_ kind: AgentApprovalDecision.Kind) -> AgentApprovalDecision? {
        let matching = decisions.filter { $0.kind == kind }
        return matching.count == 1 ? matching.first : nil
    }

    public func validate() throws(ErrorCode) {
        guard decisions.count <= 8, Set(decisions.map(\.id)).count == decisions.count, (requested?.count ?? 0) <= 64 else { throw .badRequest }
        for decision in decisions {
            guard !decision.id.isEmpty, decision.id.utf8.count <= 256, !decision.label.isEmpty, decision.label.utf8.count <= 512,
                  (decision.consequence?.utf8.count ?? 0) <= 2048, decision.kind.rawValue.utf8.count <= 64 else { throw .badRequest }
        }
        let texts = [method, summary, scope, chosen, origin?.threadID, origin?.agentID, origin?.toolUseID, origin?.name] + (requested ?? []).map { $0 }
        guard texts.allSatisfy({ ($0?.utf8.count ?? 0) <= 8192 && $0?.contains("\0") != true }) else { throw .badRequest }
    }

    /// A bound on the card's encoded size for transcript budgets.
    public var transcriptByteCount: Int {
        let texts = [method, summary, scope, chosen, origin?.threadID, origin?.agentID, origin?.toolUseID, origin?.name]
        return 256 + texts.reduce(0) { $0 + ($1?.utf8.count ?? 0) } + (requested ?? []).reduce(0) { $0 + 8 + $1.utf8.count }
            + decisions.reduce(0) { $0 + 96 + $1.id.utf8.count + $1.label.utf8.count + ($1.consequence?.utf8.count ?? 0) }
    }
}
