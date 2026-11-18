import Foundation

/// A fenced code block's opening line, as both the Markdown parser and the streaming-tail
/// filter recognize it: its marker kind (backtick or tilde), run length, info string and
/// indentation. A fence closes only on a line of the same marker, at least as long, with
/// nothing after it but spaces, so a tilde fence ignores backtick runs and a four-backtick
/// fence ignores three-backtick ones.
struct AgentMarkdownFence: Equatable, Sendable {
    let marker: Character
    let count: Int
    let info: String
    let indent: Int

    /// The fence `line` opens, or nil when it opens none.
    static func opening(_ line: String) -> AgentMarkdownFence? {
        let indent = indentation(line)
        guard indent < 4 else { return nil }
        let text = line.drop { $0 == " " || $0 == "\t" }
        guard let first = text.first, first == "`" || first == "~" else { return nil }
        let count = text.prefix { $0 == first }.count
        guard count >= 3 else { return nil }
        let info = String(text.dropFirst(count)).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        guard first != "`" || !info.contains("`") else { return nil }
        return AgentMarkdownFence(marker: first, count: count, info: info, indent: indent)
    }

    /// Whether `line` closes this fence.
    func isClosed(by line: String) -> Bool {
        guard Self.indentation(line) < 4 else { return false }
        let text = line.drop { $0 == " " || $0 == "\t" }
        let run = text.prefix { $0 == marker }.count
        return run >= count && text.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// The fence still open at the end of `lines`, read top to bottom, or nil.
    static func open<Lines: Sequence>(after lines: Lines) -> AgentMarkdownFence? where Lines.Element == String {
        var open: AgentMarkdownFence?
        for line in lines {
            if let fence = open {
                if fence.isClosed(by: line) { open = nil }
            } else {
                open = opening(line)
            }
        }
        return open
    }

    /// A line's leading indentation in columns, a tab reaching the next multiple of four.
    static func indentation(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 - $0 % 4 : 1) }
    }
}
