import AgentCore
import AppKit

/// What VoiceOver hears when a conversation changes in a way the user must know about
/// without moving the keyboard focus: an approval or question to answer, a failed turn,
/// and a finished or stopped one. Each transition is announced once, keyed by its stable
/// identity, so refreshing, reconnecting or showing the pane again never repeats it; the
/// first snapshot a pane sees, or the first after the conversation was cleared, is taken
/// as already known. Streaming text and timers never announce.
struct AgentTransitionAnnouncements {
    struct Announcement: Equatable {
        var key: String
        var text: String
        /// Needs the user's answer, or reports a failure.
        var urgent: Bool
    }

    /// Keys kept, oldest forgotten first: far more than one snapshot can hold.
    static let capacity = 2048

    private var known: Set<String> = []
    private var order: [String] = []
    private var resetID: SessionId?
    private var seeded = false

    /// The transitions `snapshot` shows that weren't announced yet, in transcript order.
    mutating func announcements(for snapshot: AgentChatSnapshot) -> [Announcement] {
        if !seeded || snapshot.resetID != resetID {
            seeded = true
            resetID = snapshot.resetID
            known.removeAll(); order.removeAll()
            for announcement in Self.transitions(snapshot) { remember(announcement.key) }
            return []
        }
        return Self.transitions(snapshot).filter { remember($0.key) }
    }

    /// Records `key`; true when it is new.
    @discardableResult
    private mutating func remember(_ key: String) -> Bool {
        guard known.insert(key).inserted else { return false }
        order.append(key)
        if order.count > Self.capacity { known.remove(order.removeFirst()) }
        return true
    }

    /// Every announceable state the snapshot holds, whether announced or not.
    static func transitions(_ snapshot: AgentChatSnapshot) -> [Announcement] {
        var result: [Announcement] = []
        let agent = snapshot.provider.name
        for item in snapshot.items where item.kind == .approval && !item.isComplete {
            let text = item.questionnaire != nil ? "\(agent) asked a question."
                : "\(agent) is asking for approval" + (item.text.isEmpty ? "." : ": " + String(item.text.prefix(160)))
            result.append(Announcement(key: "approval:" + item.id, text: text, urgent: true))
        }
        if let turn = snapshot.turns?.last, let outcome = turn.outcome {
            let key = "turn:" + turn.userItemID + ":" + outcome.rawValue
            switch outcome {
            case .completed: result.append(Announcement(key: key, text: "\(agent) finished responding.", urgent: false))
            case .failed: result.append(Announcement(key: key, text: failure(snapshot, agent: agent), urgent: true))
            case .interrupted, .cancelled: result.append(Announcement(key: key, text: "\(agent) stopped.", urgent: false))
            default: break
            }
        } else if snapshot.status == .failed, snapshot.turns?.isEmpty != false,
                  let notice = snapshot.items.last(where: { $0.kind == .notice }) {
            // A server that predates turn records still marks the failure with its notice.
            result.append(Announcement(key: "failed:" + notice.id, text: failure(snapshot, agent: agent), urgent: true))
        }
        return result
    }

    private static func failure(_ snapshot: AgentChatSnapshot, agent: String) -> String {
        guard let notice = snapshot.items.last(where: { $0.kind == .notice })?.text, !notice.isEmpty else { return "\(agent) failed." }
        return "\(agent) failed: " + String(notice.prefix(200))
    }

    /// Asks VoiceOver to speak `announcement` without moving focus.
    @MainActor
    static func post(_ announcement: Announcement, from element: Any) {
        let priority: NSAccessibilityPriorityLevel = announcement.urgent ? .high : .medium
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: announcement.text, .priority: priority.rawValue])
    }
}

extension AgentPaneController {
    /// Speaks the transitions an accepted snapshot shows for the first time, leaving the
    /// keyboard focus where it is. A pane out of sight records them without speaking, so
    /// showing it later doesn't replay them.
    func announceTransitions(_ snapshot: AgentChatSnapshot) {
        let new = transitionAnnouncements.announcements(for: snapshot)
        guard !new.isEmpty, surface.window != nil, !surface.isHiddenOrHasHiddenAncestor else { return }
        for announcement in new {
            if let announceTransition { announceTransition(announcement) }
            else { AgentTransitionAnnouncements.post(announcement, from: surface) }
        }
    }
}
