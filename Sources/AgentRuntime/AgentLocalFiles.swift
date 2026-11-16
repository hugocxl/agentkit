import Foundation
import AgentCore

/// Descriptor-relative file access for local conversation previews and saved artifacts.
/// ProjectRoot resolves links without allowing traversal outside the working folder.
actor AgentLocalFiles {
    private let root: ProjectRoot
    private let project: ProjectId
    init(directory: URL, project: ProjectId) throws {
        root = try ProjectRoot(path: directory.path); self.project = project
    }
    func handle(_ request: FilesRequest) throws -> FilesReply {
        guard request.project == project else { throw ServiceError(.unknownProject, "The file belongs to another workspace.") }
        switch request.action {
        case .stat(let path): return .info(try root.info(root.resolve(path.rawValue)))
        case .read(let path): return .content(try root.read(path.rawValue))
        case .readBytes(let path): return .bytes(try root.readBytes(path.rawValue))
        case .readRange(let path, let offset, let length, let revision):
            return .byteRange(try root.readRange(path.rawValue, offset: offset, length: length, expectedRevision: revision))
        case .list(let path): return .entries(try root.list(path.rawValue, ignored: { _, _ in [] }))
        case .write(let path, let content, let parents):
            guard content.utf8.count <= AgentLimits.maxFileBytes else { throw ServiceError(.badRequest, "This file is too large.") }
            return .path(try root.write(path.rawValue, Data(content.utf8), createParents: parents))
        case .searchFiles(let requested):
            let limit = min(Int(requested), AgentLimits.maxFileSearchResults)
            guard limit > 0 else { throw ServiceError(.badRequest, "A positive file limit is required.") }
            var paths: [String] = [], pending = [""], visited = Set<String>(), scanned = 0
            while let directory = pending.popLast(), scanned < 100_000 {
                let target = try root.resolve(directory)
                let canonical = target.components.joined(separator: "/")
                guard visited.insert(canonical).inserted else { continue }
                let entries = try root.list(directory, ignored: { _, _ in [] })
                for entry in entries {
                    scanned += 1
                    if entry.isDirectory {
                        if entry.path.rawValue.split(separator: "/").count < 32 { pending.append(entry.path.rawValue) }
                    } else {
                        paths.append(entry.path.rawValue)
                        if paths.count == limit { return .fileList(.init(paths: paths, truncated: true)) }
                    }
                }
            }
            return .fileList(.init(paths: paths, truncated: !pending.isEmpty))
        default: throw ServiceError(.unsupported, "This file operation is not a conversation service.")
        }
    }
}
