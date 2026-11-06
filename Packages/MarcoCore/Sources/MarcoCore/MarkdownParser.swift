import Foundation
import Markdown

/// Parses raw Markdown text into a flat `[Block]` model.
///
/// Frontmatter (a leading `---`/`---` YAML block) is split off before
/// handing the remainder to cmark-gfm, since cmark has no concept of
/// frontmatter.
public enum MarkdownParser {

    public static func parse(_ text: String) -> [Block] {
        let text = normalizingLineEndings(text)
        var ordinal = 0
        var blocks: [Block] = []

        let (frontmatter, body) = splitFrontmatter(text)
        if let frontmatter {
            blocks.append(Block(kind: .frontmatter, rawText: frontmatter, ordinal: ordinal, startLine: -1))
            ordinal += 1
        }

        blocks.append(contentsOf: parseBody(body, startOrdinal: ordinal, lineOffset: 0))
        return Block.assigningOccurrenceIndices(to: blocks)
    }

    /// Normalizes CRLF (`\r\n`) and bare CR (`\r`) line endings to LF
    /// (`\n`), once, at every raw-text entry point (`parse`,
    /// `reparseIncremental`, `parseProgressive`). Without this, a `\r`
    /// left dangling after splitting on `\n` breaks frontmatter fence
    /// detection (`"---\r" != "---"`) and blank-separator-line checks in
    /// `IncrementalReparse`. Byte offsets/line numbers are computed AFTER
    /// normalization, so they're internally consistent even though they
    /// no longer match raw on-disk offsets for CRLF files.
    static func normalizingLineEndings(_ text: String) -> String {
        // NOTE: `text.contains("\r")` is NOT a valid fast-path check here —
        // Swift's `Character`/grapheme-cluster model fuses "\r\n" into a
        // single `Character`, so a plain `Character`-based `contains("\r")`
        // check misses it entirely. Check unicode scalars instead, which
        // see "\r" and "\n" as distinct code points regardless of
        // grapheme clustering.
        guard text.unicodeScalars.contains(where: { $0 == "\r" }) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Parses a frontmatter-free slice of body text into blocks, continuing
    /// ordinals from `startOrdinal` and offsetting `Block.startLine` by
    /// `lineOffset` so a block parsed from a slice of a larger document
    /// carries the line number it would have had from a full-document
    /// parse. Shared by `parse(_:)`, the progressive/chunked parser, and
    /// incremental reparse.
    static func parseBody<S: StringProtocol>(_ body: S, startOrdinal: Int, lineOffset: Int) -> [Block] {
        // swift-markdown parses against cmark-gfm, which enables the GFM
        // extensions (tables, task lists, strikethrough, autolinks) by
        // default — no extra options needed.
        let bodyString = String(body)
        let document = Document(parsing: bodyForParsing(bodyString))

        // Split once and reuse for every block: `sourceText` used to
        // re-split `body` per block, which is O(n) per call and thus
        // O(n * blockCount) overall — effectively quadratic and, per the
        // Spike A perf spike, ~3.5 *minutes* to parse a 1 MB fixture.
        let bodyLines = bodyString.split(separator: "\n", omittingEmptySubsequences: false)

        var ordinal = startOrdinal
        var blocks: [Block] = []
        blocks.reserveCapacity(document.childCount)

        for child in document.children {
            let kind = blockKind(for: child)
            let (rawText, startLine) = sourceTextAndStartLine(for: child, lines: bodyLines, fallback: bodyString)
            blocks.append(Block(kind: kind, rawText: rawText, ordinal: ordinal, startLine: startLine + lineOffset))
            ordinal += 1
        }

        return blocks
    }

    /// cmark consumes some footnote definitions as link definitions.
    /// Break that syntax only for parsing; block raw text still comes from the original lines.
    public static func bodyForParsing(_ body: String) -> String {
        guard body.contains("[^") else { return body }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        let candidates = lines.indices.filter {
            lines[$0].range(of: #"^ {0,3}\[\^[^\]\s]+\]:"#, options: .regularExpression) != nil
        }
        guard !candidates.isEmpty else { return body }
        let original = Document(parsing: body)
        var codeLines: Set<Int> = []
        func collectCode(_ node: any Markup) {
            if (node is CodeBlock || node is InlineCode || node is HTMLBlock), let range = node.range {
                codeLines.formUnion((range.lowerBound.line - 1)...(range.upperBound.line - 1))
            }
            for child in node.children { collectCode(child) }
        }
        collectCode(original)
        var prepared = lines.map(String.init)
        for line in candidates where !codeLines.contains(line) {
            if let separator = prepared[line].range(of: "]:") {
                prepared[line].replaceSubrange(separator, with: "]\\:")
            }
        }
        return prepared.joined(separator: "\n")
    }

    // MARK: - Frontmatter

    /// Returns `(frontmatterBlock, remainingBody)`. `frontmatterBlock` is
    /// `nil` if the document doesn't start with a `---` fence.
    ///
    /// Rule: a leading `---` line is only treated as a frontmatter opener
    /// if (a) there is a later line that is exactly `---` (the closer),
    /// AND (b) at least one line strictly between opener and closer looks
    /// like a YAML key — matches `^[A-Za-z0-9_-]+\s*:` once trimmed. This
    /// guards against a document that legitimately *starts* with a
    /// thematic break (`---`) followed later by another unrelated `---`
    /// (another thematic break, or a setext heading underline) — with no
    /// `key:`-shaped line in between, it's treated as ordinary content
    /// instead of swallowed as frontmatter. Known limitation (not
    /// over-engineered further): a body that coincidentally contains a
    /// `key:`-looking line of prose before a later unrelated `---` will
    /// still be misdetected as frontmatter; disambiguating that requires
    /// real YAML validation, which is out of scope here.
    static func splitFrontmatter(_ text: String) -> (String?, String) {
        guard text.hasPrefix("---") else { return (nil, text) }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---" else { return (nil, text) }

        for index in lines.indices.dropFirst() {
            guard lines[index] == "---" else { continue }
            guard index > 1, lines[1..<index].contains(where: looksLikeYAMLKeyLine) else { continue }

            let frontmatterLines = lines[0...index]
            let frontmatter = frontmatterLines.joined(separator: "\n")
            let remainingLines = lines[(index + 1)...]
            let body = remainingLines.joined(separator: "\n")
            return (frontmatter, body)
        }
        return (nil, text)
    }

    /// How many lines of `text` are the frontmatter block (0 if none) —
    /// the offset to add to a body-relative `Block.startLine` to get the
    /// absolute line number in the full file text, or to subtract from an
    /// absolute line (e.g. a source editor's caret line) to get a
    /// body-relative one. Used by the M3 editor mode transition (PLAN §2
    /// J4) to map between blocks and caret/scroll position without
    /// duplicating frontmatter-detection logic outside this module.
    public static func bodyLineOffset(in text: String) -> Int {
        let normalized = normalizingLineEndings(text)
        let (frontmatter, _) = splitFrontmatter(normalized)
        guard let frontmatter else { return 0 }
        return frontmatter.components(separatedBy: "\n").count
    }

    private static let yamlKeyPattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_-]+\s*:"#)

    private static func looksLikeYAMLKeyLine(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return yamlKeyPattern.firstMatch(in: trimmed, range: range) != nil
    }

    // MARK: - Block classification

    private static func blockKind(for markup: any Markup) -> BlockKind {
        switch markup {
        case let heading as Heading:
            return .heading(level: heading.level)
        case is Paragraph:
            return .paragraph
        case let codeBlock as CodeBlock:
            return .codeBlock(language: codeBlock.language)
        case is UnorderedList, is OrderedList:
            return .list
        case is Table:
            return .table
        case is BlockQuote:
            return .blockquote
        case is ThematicBreak:
            return .thematicBreak
        case is HTMLBlock:
            return .htmlBlock
        default:
            return .paragraph
        }
    }

    /// swift-markdown gives us a `SourceRange` for each top-level node
    /// (relative to the parsed `body`); slice the original text so the
    /// block's `rawText` is exactly what cmark saw, not a re-serialized
    /// approximation. Also returns the 0-based body line the block starts
    /// on, used for incremental reparse.
    private static func sourceTextAndStartLine(
        for markup: any Markup, lines: [Substring], fallback body: String
    ) -> (text: String, startLine: Int) {
        guard let range = markup.range else {
            return (markup.format(), -1)
        }
        let startLine = range.lowerBound.line - 1
        let endLine = range.upperBound.line - 1
        guard startLine >= 0, endLine < lines.count, startLine <= endLine else {
            return (markup.format(), -1)
        }
        return (lines[startLine...endLine].joined(separator: "\n"), startLine)
    }
}
