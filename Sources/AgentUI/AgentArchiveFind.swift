import AgentCore
import AppKit

/// An item of the server's archive holding Find's query, not yet loaded into the pane.
struct AgentArchiveFindHit: Equatable {
    var itemID: String
    /// Its archive position.
    var position: Int
    /// How many occurrences it holds.
    var count: Int
}

/// Find's search of the conversation's archived items, which the pane holds only once
/// their pages load. It reads the archive a page at a time through the server and
/// searches each item exactly as Find searches shown ones, then says how far it got:
/// a search that is still going, stopped, failed, or couldn't reach history the server
/// didn't keep never reads as a complete "no results".
enum AgentArchiveFindState: Equatable {
    case idle
    case searching(hits: [AgentArchiveFindHit], scanned: Int, total: Int)
    case complete(hits: [AgentArchiveFindHit], scanned: Int, missing: Int)
    case stopped(hits: [AgentArchiveFindHit], scanned: Int, total: Int, failed: Bool)

    var hits: [AgentArchiveFindHit] {
        switch self {
        case .idle: []
        case .searching(let hits, _, _), .complete(let hits, _, _), .stopped(let hits, _, _, _): hits
        }
    }

    /// The hits not among `shown` item IDs, oldest first.
    func pending(excluding shown: Set<String>) -> [AgentArchiveFindHit] {
        hits.filter { !shown.contains($0.itemID) }.sorted { $0.position < $1.position }
    }

    /// What follows the match counter: where else matches are and what wasn't searched.
    func scope(excluding shown: Set<String>) -> String {
        let pending = pending(excluding: shown).reduce(0) { $0 + $1.count }
        let found = pending == 0 ? "" : " · \(pending) in earlier history"
        switch self {
        case .idle: return ""
        case .searching(_, let scanned, let total):
            return found + " · searching earlier history (\(scanned) of \(total))"
        case .complete(_, _, let missing):
            return found + (missing > 0 ? " · \(missing) older messages weren't kept and weren't searched" : "")
        case .stopped(_, let scanned, let total, let failed):
            return found + " · " + (failed ? "earlier history search failed" : "earlier history search stopped")
                + " after \(scanned) of \(total) messages"
        }
    }

    /// The occurrences of `query` in `item`, as Find counts them in a shown item.
    @MainActor
    static func occurrences(of query: String, in item: AgentChatItem, render: (AgentChatItem) -> String?) -> Int {
        guard let source = AgentConversationFindModel.searchableText(item),
              AgentConversationFindModel.mayMatch(query, renderedFrom: source) else { return 0 }
        return AgentConversationFindModel.ranges(of: query, in: render(item) ?? source).count
    }
}

extension AgentPaneController {
    /// Connects Find in the transcript to the archive search.
    func installArchiveFind() {
        surface.onFindQuery = { [weak self] query in self?.searchArchive(query) }
        surface.onRevealArchived = { [weak self] hit, last in self?.revealArchived(hit, last: last) }
        surface.onStopArchiveSearch = { [weak self] in self?.stopArchiveSearch() }
    }

    /// Searches the archived items above those loaded for `query`; an empty query, or
    /// none archived, ends any search.
    func searchArchive(_ query: String) {
        archiveFindTask?.cancel()
        archiveFindTask = nil
        guard !query.isEmpty, !disposedForFind, let request = conversationRequest, let snapshot,
              (snapshot.omittedItems ?? 0) > 0, earlierTimeline.canLoadOlder || earlierTimeline.items.isEmpty else {
            surface.setArchiveFind(.idle)
            return
        }
        let session = session, resetID = snapshot.resetID, omitted = snapshot.omittedItems ?? 0
        let first = earlierTimeline.nextBefore
        archiveFindTask = Task { [weak self] in
            var hits: [AgentArchiveFindHit] = []
            var scanned = 0
            var total = first ?? omitted
            var before = first
            guard let self else { return }
            self.surface.setArchiveFind(.searching(hits: [], scanned: 0, total: total))
            do {
                while before != 0 {
                    guard case .earlier(let page) = try await request(.earlier(session: session, before: before, limit: AgentEarlierItems.maxItems)) else {
                        throw ModelError("The server sent an unexpected reply.")
                    }
                    try Task.checkCancellation()
                    guard self.snapshot?.resetID == resetID else { throw CancellationError() }
                    if before == nil { total = page.total }
                    if let before, page.start >= before { break }
                    for (offset, item) in page.items.enumerated() {
                        let count = AgentArchiveFindState.occurrences(of: query, in: item) { [weak self] in self?.surface.renderedFindText($0) }
                        if count > 0 { hits.append(AgentArchiveFindHit(itemID: item.id, position: page.start + offset, count: count)) }
                    }
                    scanned += page.items.count
                    self.surface.setArchiveFind(.searching(hits: hits, scanned: scanned, total: total))
                    if page.items.isEmpty { break }
                    before = page.start
                }
                self.surface.setArchiveFind(.complete(hits: hits, scanned: scanned, missing: max(0, omitted - total)))
            } catch is CancellationError {
                guard !Task.isCancelled || self.archiveFindStopped else { return }
                self.surface.setArchiveFind(.stopped(hits: hits, scanned: scanned, total: total, failed: false))
            } catch {
                self.surface.setArchiveFind(.stopped(hits: hits, scanned: scanned, total: total, failed: true))
            }
            self.archiveFindStopped = false
        }
    }

    /// Stops the archive search, keeping what it found and saying where it stopped.
    func stopArchiveSearch() {
        guard let archiveFindTask else { return }
        archiveFindStopped = true
        archiveFindTask.cancel()
    }

    /// Loads pages until `hit`'s item shows, then selects its first or last occurrence.
    func revealArchived(_ hit: AgentArchiveFindHit, last: Bool) {
        archiveRevealTask?.cancel()
        archiveRevealTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.surface.snapshot?.items.contains(where: { $0.id == hit.itemID }) != true {
                guard await self.loadEarlierPage() else { break }
            }
            guard !Task.isCancelled else { return }
            if !self.surface.selectFindMatch(itemID: hit.itemID, last: last) {
                self.showNotice("That match is no longer in this conversation's history.", kind: .info)
            }
        }
    }
}

extension AgentPaneView {
    /// Shows the archive search's progress beside the match counter.
    func setArchiveFind(_ state: AgentArchiveFindState) {
        archiveFind = state
        refreshFindCounter()
    }

    /// The match counter followed by the archive search's scope.
    func refreshFindCounter() {
        guard let model = findModel else { return }
        let shown = Set(snapshot?.items.map(\.id) ?? [])
        let pending = archiveFind.pending(excluding: shown)
        var counter = model.counter
        if counter == "No results", !pending.isEmpty { counter = "None shown" }
        findBar?.counter = counter + (model.query.isEmpty ? "" : archiveFind.scope(excluding: shown))
    }

    /// Selects the first or last occurrence in `itemID` and reveals it; false when it isn't shown.
    @discardableResult
    func selectFindMatch(itemID: String, last: Bool) -> Bool {
        guard var model = findModel, model.select(itemID: itemID, last: last) else { return false }
        findModel = model
        findSelectionDidChange()
        return true
    }
}
