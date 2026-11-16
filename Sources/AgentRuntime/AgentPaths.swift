import Foundation

enum AgentPaths {
    static func isInside(_ path: String, _ root: String) -> Bool {
        let path = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let root = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        return path == root || path.hasPrefix(root == "/" ? root : root + "/")
    }
}
