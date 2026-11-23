import Foundation

/// A client-generated identity is retained across retries, including reconnects.
public struct AgentPrompt: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var model: String?
    public var effort: AgentReasoningEffort?
    public var provider: AgentChatProvider
    /// Which of the backend's providers of `provider`'s kind runs it; nil is the kind's built-in one.
    public var providerID: String?
    public var planMode: Bool
    public var attachments: [AgentChatAttachment]
    public init(id: String = UUID().uuidString, text: String, model: String?, effort: AgentReasoningEffort?,
                provider: AgentChatProvider, providerID: String? = nil, planMode: Bool, attachments: [AgentChatAttachment] = []) {
        self.id = id; self.text = text; self.model = model; self.effort = effort
        self.provider = provider; self.providerID = providerID; self.planMode = planMode; self.attachments = attachments
    }
    public func validate() throws(ErrorCode) {
        guard UUID(uuidString: id) != nil else { throw .badRequest }
        try AgentChatRequest.send(session: SessionId(), text: text, model: model, reasoningEffort: effort,
                                  provider: provider, attachments: attachments, providerID: providerID).validate()
    }
}

/// Payload-free queue metadata is shared by all clients of the conversation.
public struct AgentQueuedPrompt: Codable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case queued, delivering, uncertain, failed }
    public var id: String
    public var text: String
    public var attachments: [AgentChatAttachmentDescriptor]
    public var state: State
    public var revision: UInt64
    public var error: String?
    public init(prompt: AgentPrompt, state: State = .queued, revision: UInt64 = 0, error: String? = nil) {
        id = prompt.id; text = prompt.text; attachments = prompt.attachments.map(\.descriptor)
        self.state = state; self.revision = revision; self.error = error
    }
}

public struct AgentQuestionnaire: Codable, Hashable, Sendable {
    public struct Option: Codable, Hashable, Sendable {
        public var label: String
        public var description: String?
        public init(label: String, description: String? = nil) { self.label = label; self.description = description }
    }
    public struct Question: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var options: [Option]
        public var multiple: Bool
        public var secret: Bool
        public var required: Bool
        public init(id: String, title: String, options: [Option] = [], multiple: Bool = false,
                    secret: Bool = false, required: Bool = true) {
            self.id = id; self.title = title; self.options = options; self.multiple = multiple
            self.secret = secret; self.required = required
        }
    }
    public var questions: [Question]
    public init(questions: [Question]) { self.questions = questions }
    public func validate() throws(ErrorCode) {
        guard transcriptByteCount <= 64 * 1024, !questions.isEmpty, questions.count <= 12, Set(questions.map(\.id)).count == questions.count else { throw .badRequest }
        for q in questions {
            try AgentValidation.message(q.id, limit: 1024)
            try AgentValidation.message(q.title, limit: 8192)
            guard q.options.count <= 32, Set(q.options.map(\.label)).count == q.options.count else { throw .badRequest }
            for option in q.options {
                try AgentValidation.message(option.label, limit: 4096)
                if let description = option.description { try AgentValidation.message(description, limit: 8192) }
            }
        }
    }
    public func validate(answers: [String: [String]], cancelled: Bool) throws(ErrorCode) {
        guard Set(answers.keys).isSubset(of: Set(questions.map(\.id))) else { throw .badRequest }
        if cancelled { return }
        for question in questions {
            let values = answers[question.id] ?? []
            guard values.count <= (question.multiple ? 32 : 1),
                  !question.required || !values.isEmpty else { throw .badRequest }
            for value in values { try AgentValidation.message(value, limit: 16 * 1024) }
        }
    }
}

extension AgentQuestionnaire {
    public var transcriptByteCount: Int {
        questions.reduce(128) { bytes, question in
            bytes + 128 + question.id.utf8.count + question.title.utf8.count
                + question.options.reduce(0) { $0 + 64 + $1.label.utf8.count + ($1.description?.utf8.count ?? 0) }
        }
    }
}

/// Optional replacement settings when editing a pending prompt; attachments stay server-owned.
public struct AgentQueuedSettings: Codable, Hashable, Sendable {
    public var model: String?
    public var effort: AgentReasoningEffort?
    public var planMode: Bool
    public init(model: String?, effort: AgentReasoningEffort?, planMode: Bool) {
        self.model = model; self.effort = effort; self.planMode = planMode
    }
}

/// The whole new content of a queued prompt. Attachments are listed in their new order:
/// kept ones by the ID the queue shows, new ones with their bytes.
public struct AgentQueuedEdit: Codable, Hashable, Sendable {
    public enum Attachment: Codable, Hashable, Sendable {
        /// One of the prompt's current attachments.
        case keep(id: String)
        /// A new attachment, sent with its bytes.
        case add(AgentChatAttachment)
    }
    public var text: String
    /// Nil keeps the prompt's model, reasoning effort and plan mode.
    public var settings: AgentQueuedSettings?
    public var attachments: [Attachment]
    public init(text: String, settings: AgentQueuedSettings? = nil, attachments: [Attachment]) {
        self.text = text; self.settings = settings; self.attachments = attachments
    }

    /// Checks what can be checked without the queued prompt: sizes, identities and that
    /// the prompt keeps text or an attachment.
    public func validate() throws(ErrorCode) {
        guard attachments.count <= AgentChatAttachment.maxCount, text.utf8.count <= 64 * 1024 else { throw .badRequest }
        let ids = attachments.map { attachment -> String in
            switch attachment {
            case .keep(let id): return id
            case .add(let added): return added.id
            }
        }
        guard Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else { throw .badRequest }
        let added = attachments.compactMap { attachment -> AgentChatAttachment? in
            if case .add(let added) = attachment { return added }
            return nil
        }
        try AgentChatAttachment.validate(added)
        if attachments.isEmpty { try AgentValidation.message(text, limit: 64 * 1024) }
        if let model = settings?.model { try AgentValidation.message(model, limit: 256) }
        try settings?.effort?.validate()
    }
}
