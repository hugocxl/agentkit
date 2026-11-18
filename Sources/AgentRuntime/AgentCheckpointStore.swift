import AgentCore
import Darwin
import Foundation

/// Worktree snapshots use an isolated index, as in the source renderer's GitVcsDriver. Never reset,
/// stash, checkout, or stage through the user's index. Call from a blocking worker.
struct AgentCheckpointStore: Sendable {
    struct Snapshot: Codable, Hashable, Sendable {
        var tree: String
        var reference: String
        var directory: String
        /// The Git folder that keeps the ref: the repository's own, which its linked
        /// worktrees share. Snapshots taken before it was kept leave it out.
        var repository: String?

        init(tree: String, reference: String, directory: String, repository: String? = nil) {
            self.tree = tree; self.reference = reference; self.directory = directory; self.repository = repository
        }
    }


    private let git: GitCommand

    /// A capture whose ref Git may or may not have made: neither a checkpoint nor nothing,
    /// so its caller keeps `snapshot` until the ref is known to be gone.
    struct UnsettledPin: Error, CustomStringConvertible {
        let snapshot: Snapshot
        let failure: Error
        var description: String { "\(failure)" }
    }

    /// `git` runs every Git command; tests stand in another Git for it.
    init(git: GitCommand = GitCommand()) { self.git = git }
    /// Tests delay or fail a capture here, before it reads anything.
    var willCapture: (@Sendable (String) throws -> Void)?
    /// Tests fail a restore here, before it changes the file at a path.
    var willRestore: (@Sendable (String) throws -> Void)?
    private let config = ["-c", "core.fsmonitor=false", "-c", "core.splitIndex=false",
                          "-c", "core.untrackedCache=false", "-c", "core.sparseCheckout=false"]

    func capture(directory: String) throws -> Snapshot {
        try willCapture?(directory)
        let root: String
        do { root = try git.text(directory, ["rev-parse", "--show-toplevel"]) } catch {
            // Told apart from Git failing in a repository: a folder outside one never has changes recorded.
            if let probe = git.outcome(directory, ["rev-parse", "--is-inside-work-tree"]), !probe.succeeded,
               probe.stderrText.lowercased().contains("not a git repository") {
                throw AgentCheckpointUnavailable.notRepository
            }
            throw error
        }
        let index = try git.text(directory, ["rev-parse", "--path-format=absolute", "--git-path", "index"])
        let temporary = URL(fileURLWithPath: index).deletingLastPathComponent()
            .appendingPathComponent("tab-checkpoint-index-" + UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(atPath: temporary.path + ".lock")
        }
        let environment = ["GIT_INDEX_FILE": temporary.path]
        // The last capture's index for this folder knows the files earlier turns changed,
        // so only what changed since is hashed again rather than everything unstaged.
        let cache = URL(fileURLWithPath: index).deletingLastPathComponent()
            .appendingPathComponent("tab-checkpoint-index-" + Self.folderKey(directory))
        if FileManager.default.fileExists(atPath: cache.path) {
            try FileManager.default.copyItem(at: cache, to: temporary)
        } else if FileManager.default.fileExists(atPath: index) {
            try FileManager.default.copyItem(atPath: index, toPath: temporary.path)
        } else {
            try git.run(root, config + ["read-tree", "--empty"], environment: environment)
        }
        // Stage from the project directory, preserving other files in a parent
        // repository. The real index (including conflicts) remains untouched.
        try git.run(directory, config + ["add", "--all", "--", "."], environment: environment)
        let tree = try git.text(root, config + ["write-tree"], environment: environment)
        let staged = temporary.appendingPathExtension("next")
        if (try? FileManager.default.copyItem(at: temporary, to: staged)) != nil,
           (try? FileManager.default.replaceItemAt(cache, withItemAt: staged)) == nil {
            try? FileManager.default.moveItem(at: staged, to: cache)
            try? FileManager.default.removeItem(at: staged)
        }
        // Known before the ref exists, so no snapshot pins a ref it can't find again.
        let repository = try git.text(root, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        let reference = "refs/tab/checkpoints/" + UUID().uuidString.lowercased()
        let snapshot = Snapshot(tree: tree, reference: reference, directory: directory, repository: repository)
        do {
            try git.run(root, ["update-ref", reference, tree])
        } catch {
            // Git may have made the ref before failing, as when its hook outlasts the time
            // allowed. One it made counts; one that may be there is removed, and one that
            // can't be told is handed back to be kept track of, not used.
            switch try? isKept(reference, in: repository) {
            case true?: return snapshot
            case false?: throw error
            case nil:
                if (try? remove(snapshot)) != nil { throw error }
                throw UnsettledPin(snapshot: snapshot, failure: error)
            }
        }
        return snapshot
    }

    /// A short stable name for a folder, for its cached checkpoint index.
    static func folderKey(_ directory: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in directory.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return String(hash, radix: 16)
    }

    /// Summary capture needs only numstat; detailed patches are read on demand.
    func files(from before: Snapshot, to after: Snapshot) throws -> [AgentTurnCheckpoint.File] {
        guard before.directory == after.directory else { throw gitError("Checkpoint directories differ") }
        let stats = try git.run(before.directory, ["diff", "--numstat", "-z", "--no-renames",
                                                  "--relative", before.tree, after.tree, "--", "."])
        return stats.split(separator: 0).compactMap { record in
            let fields = record.split(separator: 9, maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            return .init(path: String(decoding: fields[2], as: UTF8.self),
                         additions: UInt64(String(decoding: fields[0], as: UTF8.self)),
                         deletions: UInt64(String(decoding: fields[1], as: UTF8.self)))
        }
    }

    /// `path`'s change between the snapshots' trees, with `context` unchanged lines around
    /// each change, read from the trees alone so later edits never show.
    func diff(from before: Snapshot, to after: Snapshot, path: String, context: Int = 3) throws -> GitDiff {
        guard before.directory == after.directory else { throw gitError("Checkpoint directories differ") }
        let (data, truncated) = try git.diff(before.directory,
            ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--relative",
             "--src-prefix=a/", "--dst-prefix=b/", "--unified=\(max(0, context))", before.tree, after.tree, "--", path], noIndex: false)
        return GitParsing.diff(GitRawDiff(diff: String(decoding: data, as: UTF8.self), truncated: truncated))
    }

    /// A file as a tree holds it: its mode and blob, or nil when the tree doesn't have it.
    struct Entry: Equatable, Sendable {
        var mode: String
        var blob: String
    }

    /// `path`, relative to the snapshot's directory, in `tree`.
    func entry(in tree: String, path: String, directory: String) throws -> Entry? {
        let output = try git.run(directory, ["ls-tree", "-z", tree, "--", path])
        guard let record = output.split(separator: 0).first,
              let tab = record.firstIndex(of: 9) else { return nil }
        let fields = String(decoding: record[record.startIndex..<tab], as: UTF8.self).split(separator: " ")
        guard fields.count == 3, fields[1] == "blob" else {
            throw gitError("\(path) is not a file in this checkpoint")
        }
        return Entry(mode: String(fields[0]), blob: String(fields[2]))
    }

    /// The working copy of `path` as Git would store it now, or nil when it is gone.
    func current(path: String, directory: String) throws -> Entry? {
        let url = try Self.file(path, in: directory)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            let hash = try git.run(directory, ["hash-object", "--stdin"], input: Data(target.utf8))
            return Entry(mode: "120000", blob: String(decoding: hash, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return Entry(mode: "040000", blob: "") }
        let executable = ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111 != 0
        return Entry(mode: executable ? "100755" : "100644", blob: try git.text(directory, ["hash-object", "--", path]))
    }

    /// The paths among `paths` whose working copy no longer matches the turn's after state.
    func changedSince(_ after: Snapshot, paths: [String]) throws -> [String] {
        try paths.filter { path in
            let expected = try entry(in: after.tree, path: path, directory: after.directory)
            let now = try current(path: path, directory: after.directory)
            return expected?.blob != now?.blob || (expected != nil && now != nil && Self.executable(expected) != Self.executable(now))
        }
    }

    /// The paths among `paths` already as the `before` snapshot has them, absent ones included.
    func matching(_ before: Snapshot, paths: [String]) throws -> [String] {
        try paths.filter { path in
            let expected = try entry(in: before.tree, path: path, directory: before.directory)
            let now = try current(path: path, directory: before.directory)
            return expected?.blob == now?.blob && Self.executable(expected) == Self.executable(now)
        }
    }

    /// Puts each of `paths` back as the `before` snapshot had it: its content and mode, or
    /// removes a file the turn added. Only the working copies of those paths change; the
    /// index, branches and every other file are left alone. Every path is checked and read
    /// before any changes, so a refusal changes nothing; a failure part way puts the files
    /// already changed back as they were and throws `AgentRestoreFailure`, which says which,
    /// if any, couldn't be.
    func restore(_ before: Snapshot, paths: [String]) throws {
        let targets = try paths.map { path -> (path: String, url: URL) in
            let url = try Self.file(path, in: before.directory)
            if (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory {
                throw gitError("\(path) is a folder now, so it was left alone")
            }
            return (path, url)
        }
        let plans = try targets.map { target -> (path: String, url: URL, entry: Entry?, data: Data) in
            let entry = try entry(in: before.tree, path: target.path, directory: before.directory)
            if let entry, entry.mode != "120000", !entry.mode.hasPrefix("100") {
                throw gitError("\(target.path) can't be restored from this checkpoint")
            }
            let data = try entry.map { try git.run(before.directory, ["cat-file", "blob", $0.blob]) } ?? Data()
            return (target.path, target.url, entry, data)
        }
        // Copies of the files about to change, to put them back if a later one can't be.
        let backup = FileManager.default.temporaryDirectory.appendingPathComponent("agentkit-restore-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: backup) }
        var touched: [(path: String, url: URL, saved: URL?)] = []
        for plan in plans {
            do {
                try willRestore?(plan.path)
                var saved: URL?
                if (try? FileManager.default.attributesOfItem(atPath: plan.url.path)) != nil {
                    try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
                    let copy = backup.appendingPathComponent(String(touched.count))
                    try FileManager.default.copyItem(at: plan.url, to: copy)
                    saved = copy
                }
                touched.append((plan.path, plan.url, saved))
                if saved != nil { try FileManager.default.removeItem(at: plan.url) }
                guard let entry = plan.entry else { continue }
                try FileManager.default.createDirectory(at: plan.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if entry.mode == "120000" {
                    try FileManager.default.createSymbolicLink(atPath: plan.url.path, withDestinationPath: String(decoding: plan.data, as: UTF8.self))
                    continue
                }
                try plan.data.write(to: plan.url)
                try FileManager.default.setAttributes([.posixPermissions: entry.mode == "100755" ? 0o755 : 0o644], ofItemAtPath: plan.url.path)
            } catch {
                var rolledBack: [String] = [], changed: [String] = []
                for file in touched.reversed() {
                    do {
                        if (try? FileManager.default.attributesOfItem(atPath: file.url.path)) != nil {
                            try FileManager.default.removeItem(at: file.url)
                        }
                        if let saved = file.saved { try FileManager.default.copyItem(at: saved, to: file.url) }
                        if file.path != plan.path { rolledBack.append(file.path) }
                    } catch { changed.append(file.path) }
                }
                throw AgentRestoreFailure(path: plan.path, reason: error.localizedDescription,
                                          rolledBack: rolledBack.reversed(), changed: changed.reversed())
            }
        }
    }

    private static func executable(_ entry: Entry?) -> Bool { entry?.mode == "100755" }

    /// `path` inside `directory`; anything that would leave it is refused.
    static func file(_ path: String, in directory: String) throws -> URL {
        let root = URL(fileURLWithPath: directory).standardizedFileURL
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains(".."), url.path.hasPrefix(root.path + "/") else {
            throw AgentRuntimeError("\(path) is outside this project")
        }
        // A folder on the way that became a symbolic link must not lead out of the project.
        let realRoot = root.resolvingSymlinksInPath().path
        let realParent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard realParent == realRoot || realParent.hasPrefix(realRoot + "/") else {
            throw AgentRuntimeError("\(path) is outside this project")
        }
        return url
    }

    /// Unpins `snapshot`'s private ref. Returns once nothing is left to do: the ref is
    /// removed, already gone, holds another tree (which stays), or its repository is gone.
    /// Throws while Git can't reach or remove it, or the repository isn't this user's to
    /// change, so the caller keeps the record and tries again later.
    func remove(_ snapshot: Snapshot) throws {
        let prefix = "refs/tab/checkpoints/"
        guard snapshot.reference.hasPrefix(prefix),
              UUID(uuidString: String(snapshot.reference.dropFirst(prefix.count))) != nil,
              [40, 64].contains(snapshot.tree.count), snapshot.tree.allSatisfy(\.isHexDigit),
              let repository = try Self.repository(of: snapshot, git: git) else { return }
        // Git checks who owns a repository it finds, not one it is pointed at; this does.
        var owner = stat()
        guard stat(repository, &owner) == 0, owner.st_uid == geteuid() else {
            throw gitError("\(repository) isn't this user's, so checkpoint ref \(snapshot.reference) stays")
        }
        // Explicitly that repository, with no working tree to enter, which may be gone.
        let place = ["--git-dir=" + repository, "--work-tree=" + repository]
        // Expected-value deletion of this ref alone: not a ref somebody replaced or one it links to.
        // One Git didn't finish, as past its time limit, may still have gone: the lookup tells.
        let deletion = git.outcome(repository, place + ["update-ref", "--no-deref", "-d", snapshot.reference, snapshot.tree])
        if deletion?.succeeded == true { return }
        guard try isKept(snapshot.reference, in: repository) else { return }
        guard let value = git.outcome(repository, place + ["rev-parse", "--verify", "--quiet", snapshot.reference]) else {
            throw gitError("Git couldn't look up checkpoint ref \(snapshot.reference)")
        }
        guard value.succeeded else { throw GitCommand.failure(value) }
        // Somebody pointed it elsewhere: it stays, and no longer pins this checkpoint.
        guard GitCommand.trimmed(value.stdout) == snapshot.tree else { return }
        throw deletion.map(GitCommand.failure) ?? gitError("Git couldn't remove checkpoint ref \(snapshot.reference)")
    }

    /// Whether `repository` still has `reference`, told apart from a lookup Git couldn't
    /// make. Git before 2.43 has no `show-ref --exists` and keeps refs only as files, so
    /// there the files themselves must show it is gone.
    private func isKept(_ reference: String, in repository: String) throws -> Bool {
        let place = ["--git-dir=" + repository, "--work-tree=" + repository]
        guard let lookup = git.outcome(repository, place + ["show-ref", "--exists", reference]) else {
            throw gitError("Git couldn't look up checkpoint ref \(reference)")
        }
        switch lookup.status {
        case 0: return true
        case 2: return false
        case 129: return try Self.filesKeep(reference, in: repository)
        default:
            // A folder of other refs now named as this one: Git can't read it as a ref.
            if try Self.isFolder((repository as NSString).appendingPathComponent(reference)),
               try !Self.packedRefsHold(reference, in: repository) { return false }
            throw GitCommand.failure(lookup)
        }
    }

    /// Whether the files a Git before 2.43 keeps refs in hold `reference`: a loose ref, a
    /// link one is kept as, or a packed one.
    private static func filesKeep(_ reference: String, in repository: String) throws -> Bool {
        let loose = (repository as NSString).appendingPathComponent(reference)
        var status = stat()
        if lstat(loose, &status) == 0 {
            if status.st_mode & S_IFMT != S_IFDIR { return true }
        } else if errno != ENOENT && errno != ENOTDIR {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return try packedRefsHold(reference, in: repository)
    }

    private static func isFolder(_ path: String) throws -> Bool {
        var status = stat()
        if lstat(path, &status) == 0 { return status.st_mode & S_IFMT == S_IFDIR }
        if errno == ENOENT || errno == ENOTDIR { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func packedRefsHold(_ reference: String, in repository: String) throws -> Bool {
        let packed = (repository as NSString).appendingPathComponent("packed-refs")
        guard try exists(packed) else { return false }
        let refs = try String(contentsOfFile: packed, encoding: .utf8)
        return refs.split(separator: "\n").contains { $0.hasSuffix(" " + reference) }
    }

    /// The Git folder that keeps `snapshot`'s ref, or `nil` once it is gone. Snapshots from
    /// before the repository was kept find it from their folder, or the nearest folder above
    /// it that remains.
    private static func repository(of snapshot: Snapshot, git: GitCommand) throws -> String? {
        if let repository = snapshot.repository { return try exists(repository) ? repository : nil }
        var folder = URL(fileURLWithPath: snapshot.directory).standardizedFileURL.path
        while try !exists(folder) {
            let parent = (folder as NSString).deletingLastPathComponent
            if parent == folder || parent.isEmpty { return nil }
            folder = parent
        }
        guard let lookup = git.outcome(folder, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) else {
            throw gitError("Git couldn't find the repository of \(snapshot.directory)")
        }
        if lookup.succeeded { return GitCommand.trimmed(lookup.stdout) }
        // Git found no repository it could use. Only no `.git` up the tree, or a link to one
        // that is gone, shows the refs went with it.
        while true {
            let marker = (folder as NSString).appendingPathComponent(".git")
            if try exists(marker) { return try linkedRepository(marker, in: folder, failure: lookup) }
            let parent = (folder as NSString).deletingLastPathComponent
            if parent == folder || parent.isEmpty { return nil }
            folder = parent
        }
    }

    /// The repository a `.git` link file in `folder` leads to, when it is gone but the
    /// repository it belonged to as a linked worktree remains; `nil` when that is gone too.
    /// A folder, or a link Git couldn't follow to something there, throws `failure`.
    private static func linkedRepository(_ marker: String, in folder: String, failure: ProcessOutput) throws -> String? {
        guard let data = FileManager.default.contents(atPath: marker), let link = String(data: data, encoding: .utf8),
              link.hasPrefix("gitdir: ") else { throw GitCommand.failure(failure) }
        var target = String(link.dropFirst("gitdir: ".count))
        while target.hasSuffix("\n") || target.hasSuffix("\r") { target.removeLast() }
        let resolved = ((target as NSString).isAbsolutePath ? target : (folder as NSString).appendingPathComponent(target) as String)
        guard try !exists(resolved) else { throw GitCommand.failure(failure) }
        // A linked worktree's own folder is `<repository>/worktrees/<name>`.
        let worktrees = (resolved as NSString).deletingLastPathComponent
        guard (worktrees as NSString).lastPathComponent == "worktrees" else { return nil }
        let common = (worktrees as NSString).deletingLastPathComponent
        return try exists(common) ? common : nil
    }

    /// Whether `path` exists, following a symbolic link to what it names; throws when it
    /// can't be told, as behind a folder this process may not search.
    private static func exists(_ path: String) throws -> Bool {
        var status = stat()
        if stat(path, &status) == 0 { return true }
        if errno == ENOENT || errno == ENOTDIR { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

}

/// Why a checkpoint can't be taken in a folder.
enum AgentCheckpointUnavailable: LocalizedError, Equatable {
    case notRepository

    var errorDescription: String? {
        switch self {
        case .notRepository: "This folder isn't in a Git repository, so the files a turn changes can't be recorded."
        }
    }
}

/// A restore that stopped part way: the file it stopped at, and the files it had already
/// changed, put back as they were or, in `changed`, left restored.
struct AgentRestoreFailure: LocalizedError, Equatable {
    var path: String
    var reason: String
    var rolledBack: [String]
    var changed: [String]

    var errorDescription: String? {
        var text = "Couldn't restore \(path): \(reason)"
        if changed.isEmpty {
            text += " No files were changed."
        } else {
            text += " These files were already restored and couldn't be put back: " + changed.joined(separator: ", ") + "."
            if !rolledBack.isEmpty { text += " Put back as they were: " + rolledBack.joined(separator: ", ") + "." }
        }
        return text
    }
}

/// Detailed comparisons stay server-side; transcript summaries can be bounded
/// without losing the full checkpoint or coupling history size to diff size.
struct AgentCheckpointRecord: Codable, Sendable {
    var before: AgentCheckpointStore.Snapshot
    var after: AgentCheckpointStore.Snapshot
    var files: [AgentTurnCheckpoint.File]
}

struct AgentCheckpointPending: Codable, Sendable {
    var turnID: String
    var before: AgentCheckpointStore.Snapshot
}

extension AgentCheckpointRecord {
    func summary(id: String) -> AgentTurnCheckpoint {
        let visible = Array(files.filter { $0.path.utf8.count <= 1024 }.prefix(64))
        return AgentTurnCheckpoint(id: id, files: visible, totalFiles: files.count,
            additions: files.reduce(0) { $0 + ($1.additions ?? 0) },
            deletions: files.reduce(0) { $0 + ($1.deletions ?? 0) }, truncated: visible.count != files.count)
    }
}
