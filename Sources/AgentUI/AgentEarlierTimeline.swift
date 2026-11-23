import AgentCore
import Foundation

/// The archived items a pane loaded above a conversation's retained ones. Pages are keyed
/// by the conversation's reset, the archive cursor they were read at, and item identity:
/// a page read for an earlier reset or cursor is dropped, and an item is never shown twice.
/// When the server trims more of the conversation into its archive, the items the pane
/// was showing join the loaded ones instead of disappearing; turns of trimmed items stay
/// with them; items trimmed unseen, as across a reconnect, leave a gap that `needsFill`
/// reports until newer pages fill it.
struct AgentEarlierTimeline: Equatable {
    /// Loaded archived items, oldest first, then items trimmed while shown.
    private(set) var items: [AgentChatItem] = []
    /// The archive position of the oldest loaded item: the next older page ends there.
    private(set) var start: Int?
    /// The archive held nothing for this conversation.
    private(set) var unavailable = false
    private(set) var resetID: SessionId?
    /// The trimmed count at which the loaded items join the retained ones.
    private var joinedAt = 0
    private var lastRetained: [AgentChatItem] = []
    private var lastRetainedTurns: [AgentChatTurn] = []
    /// Turns of trimmed items carried above the retained window, so carried turns keep their shape.
    private var carriedTurns: [AgentChatTurn] = []
    private var lastOmitted = 0
    /// How many leading items in `items` haven't changed since the previous `displayed(_:)`.
    private var lead = 0
    /// How many leading items in the last `displayed(_:)` result are unchanged from the one before it.
    private(set) var unchangedLead = 0

    /// Whether an older page may be loaded.
    var canLoadOlder: Bool { !unavailable && (items.isEmpty || (start ?? 0) > 0) }
    /// Items were trimmed that the loaded ones don't hold yet.
    var needsFill: Bool { !items.isEmpty && joinedAt < lastOmitted }
    /// The cursor of the next older page.
    var nextBefore: Int? { items.isEmpty ? nil : start }

    /// Follows a snapshot of the conversation; returns whether a gap needs filling.
    @discardableResult
    mutating func observe(_ snapshot: AgentChatSnapshot) -> Bool {
        let omitted = snapshot.omittedItems ?? 0
        if snapshot.resetID != resetID {
            self = AgentEarlierTimeline()
            resetID = snapshot.resetID
        }
        defer {
            lastRetained = snapshot.items
            lastRetainedTurns = snapshot.turns ?? []
            lastOmitted = omitted
        }
        guard !items.isEmpty else {
            joinedAt = omitted
            unchangedLead = 0
            lead = 0
            return false
        }
        if omitted > lastOmitted {
            let retained = Set(snapshot.items.map(\.id))
            var known = Set(items.map(\.id))
            let trimmed = lastRetained.filter { !retained.contains($0.id) }
            var added: [AgentChatItem] = []
            for item in trimmed where known.insert(item.id).inserted {
                items.append(item)
                added.append(item)
            }
            if !added.isEmpty {
                let addedIDs = Set(added.map(\.id))
                let existingTurns = Set(carriedTurns.map(\.userItemID))
                carriedTurns.append(contentsOf: lastRetainedTurns.filter {
                    addedIDs.contains($0.userItemID) && !existingTurns.contains($0.userItemID)
                })
            }
            if joinedAt == lastOmitted, trimmed.count >= omitted - lastOmitted { joinedAt = omitted }
        }
        let retainedIDs = Set(snapshot.items.map(\.id))
        let overlaps = items.contains { retainedIDs.contains($0.id) }
        if !overlaps {
            unchangedLead = min(lead, items.count)
            lead = items.count
        } else {
            unchangedLead = 0
            lead = 0
        }
        return joinedAt < omitted
    }

    /// Adds an older page read at `before` for `resetID`, when it still applies.
    @discardableResult
    mutating func merge(older page: AgentEarlierItems, before: Int?, resetID: SessionId?, basis: Int) -> Bool {
        guard resetID == self.resetID, before == nextBefore else { return false }
        if before == nil {
            guard !page.items.isEmpty else { unavailable = true; return true }
            joinedAt = basis
        } else if let before, page.start >= before {
            unavailable = page.items.isEmpty
            return true
        }
        let known = Set(items.map(\.id))
        let fresh = page.items.filter { !known.contains($0.id) }
        if !fresh.isEmpty {
            lead = 0
            unchangedLead = 0
        }
        items = fresh + items
        start = page.start
        return true
    }

    /// Adds the newest archived items, read from the end of the archive back to items the
    /// timeline holds, for `resetID` when `basis` items had been trimmed.
    @discardableResult
    mutating func fill(newest pages: [AgentEarlierItems], resetID: SessionId?, basis: Int) -> Bool {
        guard resetID == self.resetID, !items.isEmpty else { return false }
        let tail = pages.reversed().flatMap(\.items)
        let newer = Set(tail.map(\.id))
        let kept = items.filter { !newer.contains($0.id) }
        lead = min(lead, kept.count)
        unchangedLead = min(unchangedLead, lead)
        items = kept + tail
        joinedAt = max(joinedAt, basis)
        return true
    }

    /// `snapshot` with the loaded items and carried turns above its own.
    func displayed(_ snapshot: AgentChatSnapshot) -> AgentChatSnapshot {
        guard !items.isEmpty, snapshot.resetID == resetID else { return snapshot }
        var shown = snapshot
        let retained = Set(snapshot.items.map(\.id))
        let earlier = items.filter { !retained.contains($0.id) }
        shown.items = earlier + snapshot.items
        shown.omittedItems = max(0, (snapshot.omittedItems ?? 0) - earlier.count)
        if !carriedTurns.isEmpty {
            let windowTurns = snapshot.turns ?? []
            let windowTurnIDs = Set(windowTurns.map(\.userItemID))
            let carried = carriedTurns.filter { !windowTurnIDs.contains($0.userItemID) }
            if !carried.isEmpty { shown.turns = carried + windowTurns }
        }
        return shown
    }
}
