import AgentCore
import Foundation

/// A conversation's folder as the disk has it, read off the sessions queue before a restore
/// is admitted: its identity, and its path as given and as resolved.
struct AgentRestoreFolder: Sendable {
    let folder: AgentFolder
    let paths: [String]

    init(_ directory: String) {
        folder = AgentFolder(directory)
        let given = URL(fileURLWithPath: directory).standardizedFileURL.path
        paths = Array(Set([given, URL(fileURLWithPath: given).resolvingSymlinksInPath().path])).sorted()
    }

    /// Every one of `directories`, read: call it off the sessions queue.
    static func read(_ directories: Set<String>) -> [String: AgentRestoreFolder] {
        Dictionary(uniqueKeysWithValues: directories.map { ($0, AgentRestoreFolder($0)) })
    }
}

/// A restore being applied: the folder whose files it changes, and the conversations that
/// may not start work until it ends. Confined to the sessions queue.
struct AgentRestoreReservation: Sendable {
    /// The conversation the restore is for.
    var owner: SessionId
    /// The folder it changes files in, when it changes any.
    var folder: AgentFolder?
    /// The folder's path as given and as resolved, to meet conversations whose folder wasn't
    /// read from disk when the restore was admitted.
    var paths: [String]
    /// Conversations working in that folder, or in one inside or around it, when it was admitted.
    var held: Set<SessionId>
    /// Checkpoint queues of held conversations still recording a turn's changes there: the
    /// restore applies after them, so each turn's record ends before the restore changes files.
    var captures: [DispatchQueue] = []
    /// Whether the owner itself is held too, as for a rewind, which replaces its transcript.
    /// A revert's own conversation is not: its next turn waits behind the revert instead.
    var holdsOwner: Bool

    init(owner: SessionId, folder: AgentRestoreFolder?, held: Set<SessionId>, holdsOwner: Bool) {
        self.owner = owner
        self.folder = folder?.folder
        self.paths = folder?.paths ?? []
        self.held = held
        self.holdsOwner = holdsOwner
    }

    /// Whether the conversation `session`, working in `directory`, must wait for this restore.
    /// Touches no disk, so it may run on the sessions queue.
    func holds(_ session: SessionId, directory: String) -> Bool {
        if session == owner { return holdsOwner }
        if held.contains(session) { return true }
        let other = URL(fileURLWithPath: directory).standardizedFileURL.path
        return paths.contains { mine in other == mine || other.hasPrefix(mine + "/") || mine.hasPrefix(other + "/") }
    }

    /// Whether this restore changes files `other` would also change.
    func competes(with other: AgentFolder?) -> Bool {
        guard let folder, let other else { return false }
        return folder.overlaps(other)
    }
}

/// The file work of a revert or a rewind, run on a conversation's checkpoint queue under a
/// reservation.
enum AgentRestoreWork {
    /// Puts `paths` of `record`'s turn, or all of them, back as they were before it. Files
    /// already so are listed as unchanged; files changed since the turn stop it, unless `force`.
    static func revert(_ record: AgentCheckpointRecord, paths: [String]?, force: Bool,
                       store: AgentCheckpointStore) throws -> AgentRevertReply {
        let changed = Set(record.files.map(\.path))
        let targets = paths ?? record.files.map(\.path)
        guard !targets.isEmpty, targets.allSatisfy(changed.contains) else {
            throw ServiceError(.badRequest, "Only files this turn changed can be reverted")
        }
        return try restore(targets, to: record.before, latest: { _ in record.after }, force: force, store: store)
    }

    /// Puts every file `records`' turns changed back as it was before the first of them.
    /// `records` run oldest first; each file must still match the last turn that changed it.
    static func rewind(_ records: [AgentCheckpointRecord], force: Bool,
                       store: AgentCheckpointStore) throws -> AgentRevertReply {
        guard let first = records.first else { return AgentRevertReply() }
        var latest: [String: AgentCheckpointStore.Snapshot] = [:]
        var order: [String] = []
        for record in records {
            guard record.before.directory == first.before.directory else {
                throw AgentRuntimeError("These turns ran in different folders, so their files can't be restored together.")
            }
            for file in record.files {
                if latest[file.path] == nil { order.append(file.path) }
                latest[file.path] = record.after
            }
        }
        guard !order.isEmpty else { return AgentRevertReply() }
        return try restore(order, to: first.before, latest: { latest[$0] ?? first.after }, force: force, store: store)
    }

    private static func restore(_ targets: [String], to before: AgentCheckpointStore.Snapshot,
                                latest: (String) -> AgentCheckpointStore.Snapshot, force: Bool,
                                store: AgentCheckpointStore) throws -> AgentRevertReply {
        let unchanged = Set(try store.matching(before, paths: targets))
        let remaining = targets.filter { !unchanged.contains($0) }
        if !force {
            var conflicts: [String] = []
            for path in remaining where try !store.changedSince(latest(path), paths: [path]).isEmpty {
                conflicts.append(path)
            }
            if !conflicts.isEmpty { return AgentRevertReply(conflicts: conflicts) }
        }
        if !remaining.isEmpty { try store.restore(before, paths: remaining) }
        return AgentRevertReply(reverted: remaining, unchanged: unchanged.isEmpty ? nil : targets.filter(unchanged.contains))
    }

    /// Why work in another conversation stops a restore of files it may change, or nil.
    static func blocker(submitting: Bool, delivering: Bool, status: AgentChatStatus, runningAgents: Bool) -> String? {
        if submitting || delivering || status == .working || status == .waiting {
            return "An agent in another conversation is working in this folder. Wait for it to finish or stop it first."
        }
        if runningAgents {
            return "Agents of another conversation are running in this folder. Wait for them or stop them first."
        }
        return nil
    }

    /// Says a restore is holding back work in a conversation.
    static let holdMessage = "Files are being restored in this folder. Your message wasn't sent; send it again when the restore finishes."
}

extension AgentChatTurn {
    static let checkpointReady = AgentTurnCheckpointStatus(state: .ready)
    static let checkpointCapturing = AgentTurnCheckpointStatus(state: .capturing)
}
