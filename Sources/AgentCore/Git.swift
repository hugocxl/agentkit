import Foundation

public struct GitRawDiff: Hashable, Codable, Sendable {
    public var diff: String
    /// Cut at the line limit.
    public var truncated: Bool

    public init(diff: String, truncated: Bool = false) {
        self.diff = diff
        self.truncated = truncated
    }
}

public enum GitDiffKind: OpenEnum {
    /// A `@@` hunk header.
    case hunk
    case context
    case addition
    case deletion
    case unknown(String)

    public static let knownCases: [GitDiffKind] = [.hunk, .context, .addition, .deletion]

    public var rawValue: String {
        switch self {
        case .hunk: "hunk"
        case .context: "context"
        case .addition: "addition"
        case .deletion: "deletion"
        case .unknown(let value): value
        }
    }
}

public struct GitDiffRow: Hashable, Codable, Sendable {
    public var kind: GitDiffKind
    public var oldLineNumber: UInt64?
    public var newLineNumber: UInt64?
    public var oldText: String?
    public var newText: String?
    public var text: String

    public init(kind: GitDiffKind, oldLineNumber: UInt64? = nil, newLineNumber: UInt64? = nil,
                oldText: String? = nil, newText: String? = nil, text: String) {
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.oldText = oldText
        self.newText = newText
        self.text = text
    }
}

public struct GitDiff: Hashable, Codable, Sendable {
    public var rows: [GitDiffRow]
    public var additions: UInt64
    public var deletions: UInt64
    public var truncated: Bool
    /// Git compared the file as binary, so it has no rows.
    public var binary: Bool

    public init(rows: [GitDiffRow], additions: UInt64 = 0, deletions: UInt64 = 0, truncated: Bool = false,
                binary: Bool = false) {
        self.rows = rows
        self.additions = additions
        self.deletions = deletions
        self.truncated = truncated
        self.binary = binary
    }

    /// Rows grouped by hunk header.
    public var hunks: [ArraySlice<GitDiffRow>] {
        var hunks: [ArraySlice<GitDiffRow>] = []
        var start = rows.startIndex
        for index in rows.indices where rows[index].kind == .hunk && index != start {
            hunks.append(rows[start ..< index])
            start = index
        }
        if start < rows.endIndex { hunks.append(rows[start...]) }
        return hunks
    }
}
