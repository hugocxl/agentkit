import AgentCore
import CryptoKit
import Foundation

/// One child agent's steps as a conversation keeps them: the newest within
/// `AgentSubagentSteps.savedItems` and `savedBytes`, with how many earlier ones gave way,
/// and a revision that changes with any of them. Saved beside the conversation that
/// started the agent, under its tool call, with the project it belongs to, so a record
/// is only ever read back for the same conversation, agent and project.
struct AgentChildTranscript: Codable, Equatable, Sendable {
    var toolUseID: String
    var project: ProjectId
    var revision: UInt64 = 0
    /// Steps no longer kept, before `items`.
    var omitted: Int = 0
    var items: [AgentChatItem] = []

    init(toolUseID: String, project: ProjectId) {
        self.toolUseID = toolUseID
        self.project = project
    }

    /// All the steps the agent took, kept or not.
    var total: Int { omitted + items.count }

    /// Takes the provider's latest view of the agent's steps, its newest ones by identity:
    /// steps kept from before it stay ahead of it. True when anything changed, which
    /// moves the revision on.
    @discardableResult
    mutating func absorb(_ latest: [AgentChatItem]) -> Bool {
        var merged = items
        if let first = latest.first, let overlap = items.firstIndex(where: { $0.id == first.id }) {
            merged.removeSubrange(overlap...)
            merged += latest
        } else {
            let known = Set(latest.map(\.id))
            merged.removeAll { known.contains($0.id) }
            merged += latest
        }
        var dropped = 0
        var bytes = merged.reduce(0) { $0 + $1.transcriptByteCount }
        while merged.count > 1, merged.count > AgentSubagentSteps.savedItems || bytes > AgentSubagentSteps.savedBytes {
            bytes -= merged.removeFirst().transcriptByteCount
            dropped += 1
        }
        guard merged != items || dropped > 0 else { return false }
        items = merged
        omitted += dropped
        revision &+= 1
        return true
    }

    /// Up to `limit` steps before position `before` (the newest when nil), within one
    /// reply's bounds.
    func page(before: Int?, limit: Int = AgentSubagentSteps.maxItems) -> AgentSubagentSteps {
        let end = max(0, min(items.count, (before ?? total) - omitted))
        var start = end
        var bytes = 0
        while start > 0, end - start < min(limit, AgentSubagentSteps.maxItems) {
            let size = items[start - 1].transcriptByteCount
            guard bytes + size <= AgentSubagentSteps.maxBytes || start == end else { break }
            bytes += size
            start -= 1
        }
        return AgentSubagentSteps(toolUseID: toolUseID, items: Array(items[start..<end]), revision: revision,
                                  start: omitted + start, total: total, omitted: omitted)
    }
}

/// Where conversations' child transcripts are saved: `children/<conversation>/<agent>.json`
/// under the store. Clearing a conversation moves its folder to the archive, and deleting
/// a conversation deletes it, with everything else kept for the conversation.
enum AgentChildTranscripts {
    static let folder = "children"

    static func directory(root: URL, session: SessionId) -> URL {
        root.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(session.description, isDirectory: true)
    }

    /// The agent's file; its tool call ID, which the provider chose, is hashed into the name.
    static func file(root: URL, session: SessionId, toolUseID: String) -> URL {
        let digest = SHA256.hash(data: Data(toolUseID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory(root: root, session: session).appendingPathComponent(digest + ".json")
    }

    /// The saved steps of `toolUseID`, or nil when none were saved for this agent and project.
    static func load(root: URL, session: SessionId, toolUseID: String, project: ProjectId) -> AgentChildTranscript? {
        let url = file(root: root, session: session, toolUseID: toolUseID)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 4 * AgentSubagentSteps.savedBytes,
              let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(AgentChildTranscript.self, from: data),
              record.toolUseID == toolUseID, record.project == project else { return nil }
        return record
    }

    /// Saves `record`, then keeps the conversation's `AgentSubagentSteps.savedAgents` most
    /// recently saved agents. Runs on the store's writer.
    static func save(_ record: AgentChildTranscript, root: URL, session: SessionId) throws {
        let url = file(root: root, session: session, toolUseID: record.toolUseID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        let directory = url.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        guard files.count > AgentSubagentSteps.savedAgents else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(AgentSubagentSteps.savedAgents) where file != url {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
