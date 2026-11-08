import Foundation

/// A block-level MDX construct found by `MDXScanner.scan`. Line numbers are 0-based within the
/// scanned body (frontmatter already split off), like `Block.startLine`.
public struct MDXNode: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Top-level `import`/`export`, through the first blank line with balanced braces.
        case esm
        /// `<Name …>` … `</Name>` on their own lines; the lines between are Markdown.
        case jsxBlock
        /// `<Name … />`, possibly over several lines.
        case jsxSelfClosing
    }
    public let kind: Kind
    /// Component name (`Callout`, `Tabs.Item`); empty for `.esm`.
    public let name: String
    /// Raw attribute text between the name and `>`/`/>`, trimmed; empty for `.esm`.
    public let attributes: String
    /// The ESM statement, the opening tag, or the self-closing tag.
    public let lines: ClosedRange<Int>
    /// `.jsxBlock` only: the `</Name>` line.
    public let closingLine: Int?
    /// Source text of `lines`.
    public let source: String

    /// `.jsxBlock` only: the Markdown children between the tags.
    public var childrenLines: Range<Int>? { closingLine.map { (lines.upperBound + 1)..<$0 } }
}

/// Finds MDX constructs in `.mdx` bodies. Anything unclosed or unrecognised stays plain text;
/// lowercase tags (`<details>`, `<kbd>`, `<br>`) are HTML and left to the HTML path.
public enum MDXScanner {

    public static func scan(_ body: String) -> [MDXNode] {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var nodes: [MDXNode] = []
        var fence: String?
        var closers: Set<Int> = []
        // shortcut: after 8 full-body lookaheads, even valid deeply nested MDX stays plain text; use a parser if needed.
        var lookaheadBytes = body.utf8.count * 8
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isCloser = closers.remove(index) != nil
            if let open = fence {
                if trimmed.hasPrefix(open), trimmed.allSatisfy({ $0 == open.first }) { fence = nil }
                index += 1; continue
            }
            if let marker = fenceMarker(trimmed) { fence = marker; index += 1; continue }
            if isCloser { index += 1; continue }

            if closers.isEmpty, line.hasPrefix("import ") || line.hasPrefix("export "),
               index == 0 || lines[index - 1].trimmingCharacters(in: .whitespaces).isEmpty,
               let end = esmEnd(lines, from: index, budget: &lookaheadBytes) {
                nodes.append(MDXNode(kind: .esm, name: "", attributes: "", lines: index...end, closingLine: nil,
                                     source: lines[index...end].joined(separator: "\n")))
                index = end + 1; continue
            }
            if trimmed.hasPrefix("<"), let tag = openingTag(lines, from: index, budget: &lookaheadBytes) {
                let source = lines[index...tag.end].joined(separator: "\n")
                if tag.selfClosing {
                    nodes.append(MDXNode(kind: .jsxSelfClosing, name: tag.name, attributes: tag.attributes,
                                         lines: index...tag.end, closingLine: nil, source: source))
                    index = tag.end + 1; continue
                }
                if let closer = closingLine(for: tag.name, in: lines, after: tag.end, budget: &lookaheadBytes) {
                    nodes.append(MDXNode(kind: .jsxBlock, name: tag.name, attributes: tag.attributes,
                                         lines: index...tag.end, closingLine: closer, source: source))
                    closers.insert(closer)
                    index = tag.end + 1; continue
                }
            }
            index += 1
        }
        return nodes
    }

    /// The body with every ESM and tag line blanked (line count unchanged), so cmark parses
    /// container children as ordinary Markdown at their real line numbers.
    public static func masked(_ body: String, nodes: [MDXNode]) -> String {
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for node in nodes {
            for line in node.lines where line < lines.count { lines[line] = "" }
            if let closer = node.closingLine, closer < lines.count { lines[closer] = "" }
        }
        return lines.joined(separator: "\n")
    }

    /// `jsxInline`: balanced `{expression}` spans in a run of prose (callers pass text that is
    /// already outside code). Unbalanced braces yield nothing.
    public static func inlineExpressions(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        while let open = text[index...].firstIndex(of: "{") {
            var depth = 0, cursor = open, end: String.Index?
            while cursor < text.endIndex {
                if text[cursor] == "{" { depth += 1 }
                if text[cursor] == "}" { depth -= 1; if depth == 0 { end = cursor; break } }
                cursor = text.index(after: cursor)
            }
            guard let end else { break }
            ranges.append(open..<text.index(after: end))
            index = text.index(after: end)
        }
        return ranges
    }

    // MARK: - Pieces

    private static func fenceMarker(_ trimmed: String) -> String? {
        for char: Character in ["`", "~"] {
            let run = trimmed.prefix { $0 == char }
            if run.count >= 3 { return String(run) }
        }
        return nil
    }

    /// Last line of an ESM statement: braces balanced and the next line blank (or end of body).
    private static func esmEnd(_ lines: [String], from start: Int, budget: inout Int) -> Int? {
        var depth = 0
        for index in start..<lines.count {
            guard charge(lines[index], budget: &budget) else { return nil }
            depth += bracketDelta(lines[index])
            let nextBlank = index + 1 == lines.count || lines[index + 1].trimmingCharacters(in: .whitespaces).isEmpty
            if depth <= 0 && nextBlank { return index }
        }
        return nil
    }

    private static func bracketDelta(_ line: String) -> Int {
        var delta = 0, quote: Character?
        for char in line {
            if let q = quote { if char == q { quote = nil }; continue }
            switch char {
            case "\"", "'", "`": quote = char
            case "{", "(", "[": delta += 1
            case "}", ")", "]": delta -= 1
            default: break
            }
        }
        return delta
    }

    /// A component tag starting `lines[start]` and ending a line (`>` or `/>` then only spaces).
    private static func openingTag(_ lines: [String], from start: Int, budget: inout Int) -> (name: String, attributes: String, selfClosing: Bool, end: Int)? {
        let first = lines[start].drop { $0 == " " || $0 == "\t" }
        guard let match = first.prefixMatch(of: /<([A-Za-z_$][\w$]*(?:\.[\w$]+)*)(?=[\s\/>]|$)/) else { return nil }
        let name = String(match.1)
        guard name.first!.isUppercase || name.contains(".") else { return nil }

        var fragment = String(first[match.range.upperBound...])
        var parts: [String] = []
        var line = start
        var depth = 0, quote: Character?
        while true {
            guard charge(fragment, budget: &budget) else { return nil }
            var index = fragment.startIndex
            while index < fragment.endIndex {
                let char = fragment[index]
                if let q = quote {
                    if char == q { quote = nil }
                } else if char == "\"" || char == "'" || char == "`" {
                    quote = char
                } else if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                } else if char == ">" && depth == 0 {
                    // `<Tab>inline</Tab>` and other same-line content stay plain text.
                    guard fragment[fragment.index(after: index)...].allSatisfy(\.isWhitespace) else { return nil }
                    var inner = (parts + [String(fragment[..<index])]).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    let selfClosing = inner.hasSuffix("/")
                    if selfClosing { inner = String(inner.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
                    return (name, inner, selfClosing, line)
                }
                index = fragment.index(after: index)
            }
            parts.append(fragment)
            line += 1
            guard line < lines.count else { return nil }
            fragment = lines[line]
        }
    }

    /// The matching `</name>` line, counting nested same-name containers; skips fenced code.
    private static func closingLine(for name: String, in lines: [String], after start: Int, budget: inout Int) -> Int? {
        var depth = 1
        var fence: String?
        let opener = "<\(name)"
        let closer = "</\(name)>"
        let openerLength = opener.count
        for index in (start + 1)..<max(start + 1, lines.count) {
            guard charge(lines[index], budget: &budget) else { return nil }
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open), trimmed.allSatisfy({ $0 == open.first }) { fence = nil }
                continue
            }
            if let marker = fenceMarker(trimmed) { fence = marker; continue }
            if trimmed == closer {
                depth -= 1
                if depth == 0 { return index }
            } else if trimmed.hasPrefix(opener), !trimmed.hasSuffix("/>"),
                      trimmed.dropFirst(openerLength).first.map({ $0 == " " || $0 == ">" }) ?? true {
                depth += 1
            }
        }
        return nil
    }

    private static func charge(_ line: String, budget: inout Int) -> Bool {
        let bytes = line.utf8.count + 1
        guard bytes <= budget else { budget = 0; return false }
        budget -= bytes
        return true
    }
}
