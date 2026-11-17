import Darwin
import Foundation

/// A folder providers and reverts meet in, however its path is spelled: its identity and
/// those of the physical folders around it, so work in a folder meets work in one inside it.
/// Reading one touches the disk, so it is read off the sessions queue and outside any lock
/// a revert waits on.
struct AgentFolder: Hashable, Sendable {
    /// Its identity, as `AgentSessions.folderKey` reads it.
    let identity: String
    /// Its identity and each enclosing folder's, out to the root, under every name the system
    /// gives it: through `/private`, and through the data volume a firmlink such as `/Users`
    /// leads into.
    let lineage: Set<String>

    private static let dataVolume = "/System/Volumes/Data"

    init(_ path: String) {
        let given = URL(fileURLWithPath: path).standardizedFileURL.path
        let identity = AgentSessions.folderKey(given)
        // Only the folders it is in, not those a link on its path passes through. Foundation's
        // resolved path leaves out `/private`; the system's keeps it.
        var names: Set<String> = [URL(fileURLWithPath: given).resolvingSymlinksInPath().path]
        if let resolved = realpath(given, nil) {
            names.insert(String(cString: resolved))
            free(resolved)
        }
        for name in names {
            let other = name.hasPrefix(Self.dataVolume + "/") ? String(name.dropFirst(Self.dataVolume.count)) : Self.dataVolume + name
            if name != "/", AgentSessions.folderKey(other) == identity { names.insert(other) }
        }
        var lineage: Set<String> = [identity]
        for name in names {
            var folder = name
            while folder != "/", !folder.isEmpty {
                folder = (folder as NSString).deletingLastPathComponent
                lineage.insert(AgentSessions.folderKey(folder))
            }
        }
        self.identity = identity
        self.lineage = lineage
    }

    /// Whether work in one may change files the other holds: it is the same folder, or one
    /// is inside the other.
    func overlaps(_ other: AgentFolder) -> Bool {
        lineage.contains(other.identity) || other.lineage.contains(identity)
    }
}

/// What a revert restores files in: its folder, and the provider processes working now in a
/// folder inside or around it, wherever they launched, as in a folder moved there since.
struct AgentRevertScope: Sendable {
    let folder: AgentFolder
    /// Providers' processes found working in the folder, one inside it or one around it, or
    /// whose folder can't be told, as they may be working there.
    let processes: Set<Int32>

    /// Reads `directory`, and where each of `candidates` works now: call it off the sessions
    /// queue, as either may be on a slow volume.
    init(directory: String, candidates: [Int32]) {
        let folder = AgentFolder(directory)
        self.folder = folder
        processes = Set(candidates.filter { process in
            switch AgentProcess.workingDirectory(of: process) {
            case .folder(let path)?: return AgentFolder(path).overlaps(folder)
            case .unknown?: return true
            case nil: return false
            }
        })
    }

    /// Whether a provider that launched in `launched`, as `process` once it runs, may change
    /// files the revert restores.
    func holds(_ launched: AgentFolder, process: Int32? = nil) -> Bool {
        launched.overlaps(folder) || process.map(processes.contains) == true
    }
}
