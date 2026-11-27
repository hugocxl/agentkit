import AgentCore
import AppKit

/// A prompt sent with Send Now, followed until the server shows what became of it.
struct AgentSendNowAttempt: Equatable {
    var promptID: String
    /// The conversation's last turn when Send Now was chosen; a different one means the
    /// prompt started a turn of its own.
    var lastTurn: String?
    /// Whether the follow-up was handed to the running turn's delivery.
    var dispatched = false
    /// Why the server refused the hand-over, when it did.
    var refusal: String?
}

/// What Send Now came to, as the server reports it.
enum AgentSendNowOutcome: Equatable {
    /// It joined the running response.
    case steered
    /// The response ended first, so it started a turn of its own.
    case startedTurn
    /// It waits in the queue, for the reason given.
    case queued(String)
    /// Its delivery may or may not have reached the agent.
    case needsReview

    var message: String {
        switch self {
        case .steered: return "Sent into the current response."
        case .startedTurn: return "The response finished first, so your message started a new one."
        case .queued(let reason): return reason
        case .needsReview: return "Delivery may have reached the agent. Review the conversation before sending it again from the queue."
        }
    }
}

extension AgentPaneController {
    /// Send Now applies while the agent works and its backend can take a follow-up.
    var sendNowApplies: Bool {
        capabilities.contains(.steering) && capabilities.contains(.promptQueue)
            && (snapshot?.status == .working || snapshot?.status == .waiting)
    }

    var canSendNow: Bool {
        sendNowApplies && canSendDraft && composerWork.sendNow == nil && composerWork.sendNowTask == nil
    }

    /// The host's Send Now key: only from the composer, and only when it applies.
    func performSendNowShortcut() -> Bool {
        guard surface.composerHasFocus, !surface.composer.hasMarkedText(), surface.suggestions.isHidden, canSendNow else { return false }
        sendNow()
        return true
    }

    /// Sends the draft into the running turn instead of queueing it. The prompt keeps
    /// its queue identity: it is submitted as usual, then its delivery is asked for with
    /// its revision, so it reaches the agent at most once whatever happens in between.
    func sendNow() {
        guard canSendNow else { return }
        let text = AgentComposerCitation.prompt(from: surface.composer.attributedString())
        if let command = AgentSlashCommand(text: text), !command.isPath {
            showComposerError("Commands can't join a running response. Send them once it finishes."); return
        }
        let lastTurn = snapshot?.turns?.last?.userItemID
        send { [weak self] prompt in self?.dispatchNow(prompt, lastTurn: lastTurn) }
    }

    private func dispatchNow(_ prompt: AgentPrompt, lastTurn: String?) {
        guard !disposed else { return }
        composerWork.sendNow = AgentSendNowAttempt(promptID: prompt.id, lastTurn: lastTurn)
        // A response waiting on the user, or one that already ended, leaves it to the queue.
        guard let snapshot, snapshot.status == .working, !needsAuthoritativeSnapshot,
              let entry = snapshot.queuedPrompts?.first(where: { $0.id == prompt.id }), entry.state == .queued else {
            resolveSendNow()
            return
        }
        composerWork.sendNow?.dispatched = true
        let generation = connectionGeneration
        composerWork.sendNowTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.request(.deliverQueued(session: self.session, id: entry.id, expectedRevision: entry.revision))
                guard !self.disposed, generation == self.connectionGeneration else { return self.endSendNowTask() }
                self.composerWork.sendNowTask = nil
                self.accept(result, generation: generation)
            } catch {
                guard !self.disposed, generation == self.connectionGeneration else { return self.endSendNowTask() }
                // Refused before it began, as when the response ended or the queue changed.
                // Where the prompt is now tells what happened; it is never asked for again.
                self.composerWork.sendNow?.refusal = error.localizedDescription
                let latest = try? await self.request(.read(session: self.session))
                self.composerWork.sendNowTask = nil
                guard !self.disposed, generation == self.connectionGeneration else { return }
                if let latest { self.accept(latest, generation: generation, authoritative: true) }
            }
            self.resolveSendNow()
            self.updateControls()
        }
        updateControls()
    }

    private func endSendNowTask() {
        composerWork.sendNowTask = nil
        updateControls()
    }

    /// Reports Send Now's outcome once the server shows it. Called with every accepted snapshot.
    func resolveSendNow() {
        guard let attempt = composerWork.sendNow, let snapshot else { return }
        let entry = snapshot.queuedPrompts?.first { $0.id == attempt.promptID }
        let outcome: AgentSendNowOutcome
        switch entry?.state {
        case nil:
            outcome = snapshot.turns?.last?.userItemID != attempt.lastTurn ? .startedTurn : .steered
        case .delivering?:
            return
        case .queued?:
            // The hand-over's reply is still on its way.
            if attempt.dispatched, composerWork.sendNowTask != nil { return }
            if snapshot.status == .waiting {
                outcome = .queued("The agent is waiting for your answer, so your message is queued and goes after this response.")
            } else if let refusal = attempt.refusal {
                outcome = .queued("Couldn't send it now: \(refusal) It stays queued.")
            } else if snapshot.queuePaused == true {
                outcome = .queued("The response ended and the queue is paused. Resume the queue to send your message.")
            } else {
                outcome = .queued("Your message is queued and goes next.")
            }
        case .uncertain?, .failed?:
            outcome = .needsReview
        }
        composerWork.sendNow = nil
        composerWork.record(outcome)
        switch outcome {
        case .steered, .startedTurn: showNotice(outcome.message, kind: .info)
        case .queued, .needsReview: showNotice(outcome.message, kind: .warning)
        }
    }

    /// A reconnect before the hand-over was asked for leaves the prompt to the queue; one
    /// already asked for resolves from the new connection's snapshot.
    func sendNowConnectionChanged() {
        guard let attempt = composerWork.sendNow, !attempt.dispatched else { return }
        composerWork.sendNow = nil
        let outcome = AgentSendNowOutcome.queued("The connection changed before your message could join the response. If the server received it, it waits in the queue.")
        composerWork.record(outcome)
        showNotice(outcome.message, kind: .warning)
    }
}
