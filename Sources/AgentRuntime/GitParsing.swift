import Foundation
import AgentCore
enum GitParsing {
    static func diff(_ raw: GitRawDiff) -> GitDiff {
        var result = GitDiff(rows: [], truncated: raw.truncated)
        var old: UInt64 = 0
        var new: UInt64 = 0
        var inHunk = false
        for scalars in raw.diff.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(String.UnicodeScalarView(scalars))
            if line.unicodeScalars.last == "\r" { line.unicodeScalars.removeLast() }
            if line.hasPrefix("diff --git ") { inHunk = false }
            if line.hasPrefix("Binary files "), line.hasSuffix(" differ") {
                result.binary = true
                continue
            }
            if line.hasPrefix("@@ ") {
                let parts = line.split(separator: " ")
                func start(_ index: Int) -> UInt64 {
                    guard index < parts.count else { return 0 }
                    return UInt64(parts[index].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                old = start(1)
                new = start(2)
                inHunk = true
                result.rows.append(GitDiffRow(kind: .hunk, text: line))
                continue
            }
            guard inHunk, let first = line.unicodeScalars.first else { continue }
            let kind: GitDiffKind
            switch first {
            case " ": kind = .context
            case "+": kind = .addition
            case "-": kind = .deletion
            default: continue
            }
            let content = String(line.unicodeScalars.dropFirst())
            let hasOld = kind != .addition
            let hasNew = kind != .deletion
            result.rows.append(GitDiffRow(kind: kind, oldLineNumber: hasOld ? old : nil,
                                          newLineNumber: hasNew ? new : nil, oldText: hasOld ? content : nil,
                                          newText: hasNew ? content : nil, text: line))
            if hasOld { old += 1 }
            if hasNew { new += 1 }
            if kind == .addition { result.additions += 1 }
            if kind == .deletion { result.deletions += 1 }
        }
        return result
    }
}
