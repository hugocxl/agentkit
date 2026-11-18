/// Conversation commands that the host can bind to its menus and keyboard shortcuts.
public enum AgentShortcut: String, CaseIterable, Sendable {
    case find, findNext, findPrevious, agentPromptOutline, agentPreviousPrompt, agentNextPrompt
    case agentHistory, stopAgent, allowAgentApproval, denyAgentApproval, agentNextFailure
    case submitAgentAnswers, previousPrompt, nextPrompt, scrollToBottom
    case increaseFontSize, decreaseFontSize, toggleAgentPlan
    /// Sends the draft into the running turn instead of queueing it, where the backend can steer.
    case sendAgentPromptNow
    /// Sets the composer's draft aside in the conversation's stash.
    case stashAgentDraft
}
