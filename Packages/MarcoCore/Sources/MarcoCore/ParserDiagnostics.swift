import Foundation
import Markdown

/// Phase-by-phase timing breakdown for a single `parse` call, used by the
/// `MarcoCoreBenchmark` executable to answer "where does the time go":
/// frontmatter split vs cmark parse vs the per-block AST walk (source-text
/// slicing) vs block construction (dominated by SHA-256 hashing).
public struct ParseTiming: Sendable {
    public var frontmatterSplit: TimeInterval = 0
    public var cmarkParse: TimeInterval = 0
    public var lineSplit: TimeInterval = 0
    public var blockClassification: TimeInterval = 0
    public var sourceTextSlicing: TimeInterval = 0
    /// `Block.init`, i.e. SHA-256 hashing of each block's `rawText`.
    public var blockConstructionAndHashing: TimeInterval = 0
    public var total: TimeInterval = 0
}

extension MarkdownParser {

    /// Identical result to `parse(_:)`, plus a `ParseTiming` breakdown.
    /// Not on the hot path — the extra timer reads are cheap but
    /// non-zero, and this duplicates `parseBody`'s loop to get per-phase
    /// granularity instead of calling through it as a black box.
    public static func parseMeasured(_ text: String) -> (blocks: [Block], timing: ParseTiming) {
        var timing = ParseTiming()
        let t0 = CFAbsoluteTimeGetCurrent()

        let (frontmatter, body) = splitFrontmatter(text)
        let t1 = CFAbsoluteTimeGetCurrent()
        timing.frontmatterSplit = t1 - t0

        var ordinal = 0
        var blocks: [Block] = []
        if let frontmatter {
            blocks.append(Block(kind: .frontmatter, rawText: frontmatter, ordinal: ordinal, startLine: -1))
            ordinal += 1
        }

        let document = Document(parsing: body)
        let t2 = CFAbsoluteTimeGetCurrent()
        timing.cmarkParse = t2 - t1

        let bodyLines = body.split(separator: "\n", omittingEmptySubsequences: false)
        let t3 = CFAbsoluteTimeGetCurrent()
        timing.lineSplit = t3 - t2

        for child in document.children {
            let ta = CFAbsoluteTimeGetCurrent()
            let kind = blockKindForDiagnostics(child)
            let tb = CFAbsoluteTimeGetCurrent()
            let (rawText, startLine) = sourceTextForDiagnostics(child, lines: bodyLines, fallback: body)
            let tc = CFAbsoluteTimeGetCurrent()
            blocks.append(Block(kind: kind, rawText: rawText, ordinal: ordinal, startLine: startLine))
            let td = CFAbsoluteTimeGetCurrent()

            timing.blockClassification += tb - ta
            timing.sourceTextSlicing += tc - tb
            timing.blockConstructionAndHashing += td - tc
            ordinal += 1
        }

        timing.total = CFAbsoluteTimeGetCurrent() - t0
        return (blocks, timing)
    }

    // Diagnostics-only copies of the private classification/slicing logic
    // in MarkdownParser.swift, kept in lockstep manually since Swift has
    // no `internal(diagnostics)` access level. If these drift, the
    // benchmark's block counts (asserted against `parse(_:)`) will catch
    // it.

    fileprivate static func blockKindForDiagnostics(_ markup: any Markup) -> BlockKind {
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

    fileprivate static func sourceTextForDiagnostics(
        _ markup: any Markup, lines: [Substring], fallback body: String
    ) -> (String, Int) {
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
