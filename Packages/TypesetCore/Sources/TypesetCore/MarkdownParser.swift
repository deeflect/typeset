import Foundation
import Markdown

/// A parsed document paired with its top-level `[Block]` model so renderers
/// can reuse the AST across concurrency boundaries without re-parsing.
public struct ParsedMarkdown: @unchecked Sendable {
    public let blocks: [Block]
    public let document: Document

    public init(blocks: [Block], document: Document) {
        self.blocks = blocks
        self.document = document
    }
}

/// Parses raw Markdown text into a flat `[Block]` model.
///
/// Frontmatter (a leading `---`/`---` YAML block) is split off before
/// handing the remainder to cmark-gfm, since cmark has no concept of
/// frontmatter.
public enum MarkdownParser {

    /// `.mdx` documents get `mdx: true` (see `isMDX`): ESM is dropped, JSX tag lines become
    /// `.htmlBlock`s and container children parse as Markdown.
    public static func parse(_ text: String, mdx: Bool = false) -> [Block] {
        parseDocument(text, mdx: mdx).blocks
    }

    /// `parse`, plus the cmark document of the body, so a renderer can reuse it instead of parsing again.
    public static func parseDocument(_ text: String, mdx: Bool = false) -> (blocks: [Block], document: Document) {
        let parsed = parseDocumentResult(text, mdx: mdx)
        return (parsed.blocks, parsed.document)
    }

    /// `Sendable` variant of `parseDocument` for passing the parsed AST from
    /// reload/controller tasks into off-main renderers.
    public static func parseDocumentResult(_ text: String, mdx: Bool = false) -> ParsedMarkdown {
        let text = normalizingLineEndings(text)
        var ordinal = 0
        var blocks: [Block] = []

        let (frontmatter, body) = splitFrontmatter(text)
        if let frontmatter {
            blocks.append(Block(kind: .frontmatter, rawText: frontmatter, ordinal: ordinal, startLine: -1))
            ordinal += 1
        }

        let parsed = parseBodyAndDocument(body, startOrdinal: ordinal, lineOffset: 0, mdx: mdx)
        blocks.append(contentsOf: parsed.blocks)
        return ParsedMarkdown(blocks: Block.assigningOccurrenceIndices(to: blocks), document: parsed.document)
    }

    /// The one place that decides MDX mode: by file extension.
    public static func isMDX(_ url: URL?) -> Bool { url?.pathExtension.lowercased() == "mdx" }

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
    static func parseBody<S: StringProtocol>(_ body: S, startOrdinal: Int, lineOffset: Int, mdx: Bool = false) -> [Block] {
        parseBodyAndDocument(body, startOrdinal: startOrdinal, lineOffset: lineOffset, mdx: mdx).blocks
    }

    static func parseBodyAndDocument<S: StringProtocol>(_ body: S, startOrdinal: Int, lineOffset: Int, mdx: Bool = false) -> (blocks: [Block], document: Document) {
        // swift-markdown attaches only the table, strikethrough and task-list
        // GFM extensions; autolinks (bare URLs, `www.`, emails) are not
        // parsed and the renderer detects them in text instead.
        let bodyString = String(body)
        let mdxNodes = mdx ? MDXScanner.scan(bodyString) : []
        let document = Document(parsing: bodyForParsing(mdxNodes.isEmpty ? bodyString : MDXScanner.masked(bodyString, nodes: mdxNodes)))

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
        guard !mdxNodes.isEmpty else { return (blocks, document) }

        // Tag lines are blocks of their own (in line order) so the renderer can record them.
        var tags: [(text: String, line: Int)] = []
        for node in mdxNodes where node.kind != .esm {
            tags.append((node.source, node.lines.lowerBound))
            if let closer = node.closingLine { tags.append((String(bodyLines[closer]), closer)) }
        }
        let merged = (blocks.map { ($0.kind, $0.rawText, $0.startLine) }
                      + tags.map { (BlockKind.htmlBlock, $0.text, $0.line + lineOffset) })
            .sorted { $0.2 < $1.2 }
        return (merged.enumerated().map { Block(kind: $1.0, rawText: $1.1, ordinal: startOrdinal + $0, startLine: $1.2) }, document)
    }

    /// Byte scan for `[^`; `String.contains` is ~25× slower on large bodies.
    static func containsFootnoteMarker(_ text: String) -> Bool {
        var previous: UInt8 = 0
        for byte in text.utf8 {
            if byte == UInt8(ascii: "^"), previous == UInt8(ascii: "[") { return true }
            previous = byte
        }
        return false
    }

    /// cmark consumes some footnote definitions as link definitions.
    /// Break that syntax only for parsing; block raw text still comes from the original lines.
    public static func bodyForParsing(_ body: String) -> String {
        guard containsFootnoteMarker(body) else { return body }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        let candidates = lines.indices.filter {
            lines[$0].range(of: #"^ {0,3}\[\^[^\]\s]+\]:"#, options: .regularExpression) != nil
        }
        guard !candidates.isEmpty else { return body }
        let codeLines = nonProseLineIndices(in: lines)
        var prepared = lines.map(String.init)
        for line in candidates where !codeLines.contains(line) {
            if let separator = prepared[line].range(of: "]:") {
                prepared[line].replaceSubrange(separator, with: "]\\:")
            }
        }
        return prepared.joined(separator: "\n")
    }

    /// Linear single-pass scan for lines inside fenced code, indented code, HTML
    /// comments/raw blocks, or multi-line inline code spans so `bodyForParsing`
    /// avoids running a full extra cmark parse on footnote documents.
    private static func nonProseLineIndices(in lines: [Substring]) -> Set<Int> {
        var result: Set<Int> = []
        var fence: (char: UInt8, length: Int)?
        var inIndentedCode = false
        var prevBlank = true
        var inHTMLComment = false
        var rawHTMLTag: String?
        var inlineTicks: Int?
        var pendingInlineLines: [Int] = []

        for (index, line) in lines.enumerated() {
            let bytes = Array(line.utf8)
            let leadingSpaces = bytes.prefix(while: { $0 == UInt8(ascii: " ") }).count
            let isBlank = bytes.allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }

            if let open = fence {
                result.insert(index)
                if leadingSpaces <= 3, let run = fenceMarker(bytes, from: leadingSpaces),
                   run.char == open.char, run.length >= open.length,
                   bytes[(leadingSpaces + run.length)...].allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }) {
                    fence = nil
                }
                prevBlank = false
                continue
            }

            if isBlank {
                inlineTicks = nil
                pendingInlineLines.removeAll(keepingCapacity: true)
                prevBlank = true
                if inIndentedCode { result.insert(index) }
                continue
            }

            if inHTMLComment {
                result.insert(index)
                if line.contains("-->") { inHTMLComment = false }
                prevBlank = false
                continue
            }

            if let tag = rawHTMLTag {
                result.insert(index)
                if line.lowercased().contains("</\(tag)>") { rawHTMLTag = nil }
                prevBlank = false
                continue
            }

            let isIndented = leadingSpaces >= 4 || bytes.first == UInt8(ascii: "\t")
            if isIndented && (prevBlank || inIndentedCode) && inlineTicks == nil {
                inIndentedCode = true
                result.insert(index)
                prevBlank = false
                continue
            }
            inIndentedCode = false

            if leadingSpaces <= 3, let open = fenceMarker(bytes, from: leadingSpaces), inlineTicks == nil {
                let rest = bytes[(leadingSpaces + open.length)...]
                if open.char == UInt8(ascii: "~") || !rest.contains(UInt8(ascii: "`")) {
                    fence = open
                    result.insert(index)
                    prevBlank = false
                    continue
                }
            }

            if leadingSpaces <= 3, bytes.dropFirst(leadingSpaces).starts(with: "<!--".utf8), inlineTicks == nil {
                result.insert(index)
                if !line.contains("-->") { inHTMLComment = true }
                prevBlank = false
                continue
            }

            if leadingSpaces <= 3, inlineTicks == nil {
                let trimmedLower = String(decoding: bytes.dropFirst(leadingSpaces), as: UTF8.self).lowercased()
                for tag in ["pre", "script", "style"] where trimmedLower.hasPrefix("<\(tag)>") || trimmedLower.hasPrefix("<\(tag) ") {
                    result.insert(index)
                    if !trimmedLower.contains("</\(tag)>") { rawHTMLTag = tag }
                    break
                }
                if rawHTMLTag != nil { prevBlank = false; continue }
            }

            // Scan inline backtick runs inside the paragraph.
            var i = 0
            var lineStartedInsideInline = inlineTicks != nil
            while i < bytes.count {
                if bytes[i] == UInt8(ascii: "`") {
                    let start = i
                    while i < bytes.count, bytes[i] == UInt8(ascii: "`") { i += 1 }
                    let runLen = i - start
                    if let target = inlineTicks {
                        if runLen == target {
                            for lineIdx in pendingInlineLines { result.insert(lineIdx) }
                            if lineStartedInsideInline { result.insert(index) }
                            pendingInlineLines.removeAll(keepingCapacity: true)
                            inlineTicks = nil
                            lineStartedInsideInline = false
                        }
                    } else {
                        inlineTicks = runLen
                    }
                } else {
                    i += 1
                }
            }
            if inlineTicks != nil {
                pendingInlineLines.append(index)
            }
            prevBlank = false
        }
        return result
    }

    private static func fenceMarker(_ bytes: [UInt8], from offset: Int) -> (char: UInt8, length: Int)? {
        guard offset < bytes.count else { return nil }
        let ch = bytes[offset]
        guard ch == UInt8(ascii: "`") || ch == UInt8(ascii: "~") else { return nil }
        var len = 0
        while offset + len < bytes.count, bytes[offset + len] == ch { len += 1 }
        return len >= 3 ? (ch, len) : nil
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
