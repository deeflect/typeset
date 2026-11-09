import Foundation
import TypesetCore

/// Copy as Quote for Agent: `` `/abs/path.md:12-18` `` then the selection as
/// a Markdown quote, ready to paste into a coding agent's prompt.
enum AgentQuote {
    static func format(path: String, lines: ClosedRange<Int>, text: String) -> String {
        let span = lines.count == 1 ? "\(lines.lowerBound)" : "\(lines.lowerBound)-\(lines.upperBound)"
        // `isNewline`, not "\n": a CRLF pair is one Character in Swift.
        var body = text
        while body.last?.isNewline == true { body.removeLast() }
        let quoted = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
        return "`\(path):\(span)`\n\(quoted)"
    }

    /// 1-based file lines spanned by `blocks` (document order), given the
    /// frontmatter's line count. The frontmatter block covers lines 1...offset.
    static func lines(of blocks: [Block], bodyLineOffset offset: Int) -> ClosedRange<Int>? {
        guard let first = blocks.first, let last = blocks.last else { return nil }
        let start = first.startLine < 0 ? 1 : first.startLine + offset + 1
        let end = last.startLine < 0 ? offset : last.startLine + offset + lineCount(last.rawText)
        return start...max(start, end)
    }

    /// 1-based lines of `range` within `text` (the source editor's selection).
    static func lines(in text: NSString, range: NSRange) -> ClosedRange<Int> {
        let start = lineCount(text.substring(to: range.location) + "x")
        return start...(start + lineCount(text.substring(with: range)) - 1)
    }

    /// Lines in `raw`, ignoring trailing newlines ("" and "a" are both 1).
    /// Counts scalars, so CRLF (one Character) still counts as a line break.
    static func lineCount(_ raw: String) -> Int {
        var scalars = raw.unicodeScalars[...]
        while let last = scalars.last, last == "\n" || last == "\r" { scalars = scalars.dropLast() }
        return scalars.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }
}
