import Foundation
import Markdown

/// Parses raw Markdown text into a flat `[Block]` model.
///
/// Frontmatter (a leading `---`/`---` YAML block) is split off before
/// handing the remainder to cmark-gfm, since cmark has no concept of
/// frontmatter.
public enum MarkdownParser {

    public static func parse(_ text: String) -> [Block] {
        var ordinal = 0
        var blocks: [Block] = []

        let (frontmatter, body) = splitFrontmatter(text)
        if let frontmatter {
            blocks.append(Block(kind: .frontmatter, rawText: frontmatter, ordinal: ordinal))
            ordinal += 1
        }

        // swift-markdown parses against cmark-gfm, which enables the GFM
        // extensions (tables, task lists, strikethrough, autolinks) by
        // default — no extra options needed.
        let document = Document(parsing: body)

        // Split once and reuse for every block: `sourceText` used to
        // re-split `body` per block, which is O(n) per call and thus
        // O(n * blockCount) overall — effectively quadratic and, per the
        // Spike A perf spike, ~3.5 *minutes* to parse a 1 MB fixture.
        let bodyLines = body.split(separator: "\n", omittingEmptySubsequences: false)

        for child in document.children {
            let kind = blockKind(for: child)
            let rawText = sourceText(for: child, lines: bodyLines, fallback: body)
            blocks.append(Block(kind: kind, rawText: rawText, ordinal: ordinal))
            ordinal += 1
        }

        return blocks
    }

    // MARK: - Frontmatter

    /// Returns `(frontmatterBlock, remainingBody)`. `frontmatterBlock` is
    /// `nil` if the document doesn't start with a `---` fence.
    static func splitFrontmatter(_ text: String) -> (String?, String) {
        guard text.hasPrefix("---") else { return (nil, text) }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---" else { return (nil, text) }

        for index in lines.indices.dropFirst() {
            if lines[index] == "---" {
                let frontmatterLines = lines[0...index]
                let frontmatter = frontmatterLines.joined(separator: "\n")
                let remainingLines = lines[(index + 1)...]
                let body = remainingLines.joined(separator: "\n")
                return (frontmatter, body)
            }
        }
        return (nil, text)
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
    /// approximation.
    private static func sourceText(for markup: any Markup, lines: [Substring], fallback body: String) -> String {
        guard let range = markup.range else {
            return markup.format()
        }
        let startLine = range.lowerBound.line - 1
        let endLine = range.upperBound.line - 1
        guard startLine >= 0, endLine < lines.count, startLine <= endLine else {
            return markup.format()
        }
        return lines[startLine...endLine].joined(separator: "\n")
    }
}
