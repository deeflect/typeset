import Foundation
import Testing
@testable import TypesetCore

struct MarkdownParserTests {

    @Test func bareURLFootnotePreparationPreservesSourceAndCode() {
        let source = "Ref[^a] [normal][link].\n\n```md\n[^code]: https://inside.example\n```\n\n    [^indent]: https://inside.example\n\n[^a]: https://example.com\n\n[link]: https://reference.example\n"
        let prepared = MarkdownParser.bodyForParsing(source)
        #expect(prepared.contains("[^code]: https://inside.example"))
        #expect(prepared.contains("[^indent]: https://inside.example"))
        #expect(prepared.contains("[link]: https://reference.example"))
        #expect(prepared.contains("[^a]\\: https://example.com"))
        let blocks = MarkdownParser.parse(source)
        #expect(blocks.contains { $0.startLine == 8 && $0.rawText == "[^a]: https://example.com" })
        #expect(blocks.contains { $0.kind == .codeBlock(language: "md") && $0.rawText.contains("[^code]: https://inside.example") })
    }

    @Test func multilineInlineCodeDoesNotBecomeFootnote() {
        let source = "`before\n[^a]: https://example.com\nafter`\n"
        #expect(MarkdownParser.bodyForParsing(source) == source)
    }

    @Test func frontmatterIsSplitIntoItsOwnBlock() {
        let text = """
        ---
        title: Hello
        draft: true
        ---
        # Heading

        Body text.
        """
        let blocks = MarkdownParser.parse(text)
        #expect(blocks.first?.kind == .frontmatter)
        #expect(blocks.first?.rawText.hasPrefix("---") == true)
        #expect(blocks.first?.rawText.hasSuffix("---") == true)
        #expect(blocks.dropFirst().first?.kind == .heading(level: 1))
    }

    @Test func documentWithoutFrontmatterHasNoFrontmatterBlock() {
        let blocks = MarkdownParser.parse("# Title\n\nSome text.")
        #expect(!blocks.contains { $0.kind == .frontmatter })
    }

    @Test func codeFenceCapturesLanguage() {
        let text = """
        ```swift
        let x = 1
        ```
        """
        let blocks = MarkdownParser.parse(text)
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .codeBlock(language: "swift"))
    }

    @Test func tableIsRecognized() {
        let text = """
        | A | B |
        |---|---|
        | 1 | 2 |
        """
        let blocks = MarkdownParser.parse(text)
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .table)
    }

    @Test func taskListIsRecognizedAsList() {
        let text = """
        - [ ] todo
        - [x] done
        """
        let blocks = MarkdownParser.parse(text)
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .list)
        #expect(blocks[0].rawText.contains("[ ]"))
        #expect(blocks[0].rawText.contains("[x]"))
    }

    @Test func nestedListIsSingleListBlock() {
        let text = """
        - one
          - one.one
          - one.two
        - two
        """
        let blocks = MarkdownParser.parse(text)
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .list)
    }

    @Test func duplicateContentBlocksGetLocalOccurrenceDisambiguatedIdentities() {
        // Three identical thematic breaks anywhere in a document get 3
        // distinct, stable ids disambiguated by LOCAL occurrence index
        // among same-hash duplicates (not global ordinal/position).
        let text = "Intro paragraph.\n\n---\n\nMiddle paragraph.\n\n---\n\nAnother paragraph.\n\n---\n\nTail paragraph."
        let blocks = MarkdownParser.parse(text)
        let breaks = blocks.filter { $0.kind == .thematicBreak }
        #expect(breaks.count == 3)
        #expect(Set(breaks.map(\.id)).count == 3, "each duplicate thematic break must have a distinct id")
        #expect(breaks.allSatisfy { $0.contentHash == breaks[0].contentHash })

        // Inserting a 4th identical thematic break anywhere shouldn't
        // change the ids of the first three: they're the first three
        // blocks in document order to share that hash, regardless of
        // what's inserted after them.
        let extended = text + "\n\n---\n\nExtra tail paragraph."
        let extendedBlocks = MarkdownParser.parse(extended)
        let extendedBreaks = extendedBlocks.filter { $0.kind == .thematicBreak }
        #expect(extendedBreaks.count == 4)
        #expect(Array(extendedBreaks.prefix(3).map(\.id)) == breaks.map(\.id))
    }

    // MARK: - Frontmatter edge cases

    @Test func leadingThematicBreakWithoutAKeyLineIsNotTreatedAsFrontmatter() {
        let text = "---\n\nJust a paragraph, no frontmatter here."
        let blocks = MarkdownParser.parse(text)
        #expect(!blocks.contains { $0.kind == .frontmatter })
        #expect(blocks.first?.kind == .thematicBreak)
    }

    @Test func leadingThematicBreakFollowedByAnotherThematicBreakWithoutAKeyLineIsNotFrontmatter() {
        let text = "---\n\nJust body prose, no YAML keys anywhere.\n\n---\n\nMore prose after the second break."
        let blocks = MarkdownParser.parse(text)
        #expect(!blocks.contains { $0.kind == .frontmatter })
        #expect(blocks.filter { $0.kind == .thematicBreak }.count == 2)
    }

    @Test func documentThatIsOnlyAThematicBreakIsNotFrontmatter() {
        let blocks = MarkdownParser.parse("---")
        #expect(!blocks.contains { $0.kind == .frontmatter })
        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .thematicBreak)
    }

    // MARK: - CRLF handling

    @Test func crlfDocumentParsesEquivalentlyToLFDocument() {
        let lf = "---\ntitle: Hello\ndraft: true\n---\n\n# Heading\n\nBody text."
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")

        let lfBlocks = MarkdownParser.parse(lf)
        let crlfBlocks = MarkdownParser.parse(crlf)

        #expect(crlfBlocks.map(\.kind) == lfBlocks.map(\.kind))
        #expect(crlfBlocks.map(\.rawText) == lfBlocks.map(\.rawText))
        #expect(crlfBlocks.map(\.id) == lfBlocks.map(\.id))
        #expect(crlfBlocks.first?.kind == .frontmatter)
    }

    @Test func crlfIncrementalReparseMatchesFullReparseAndStaysFast() {
        let sections = (0..<3_000).map { i in
            "## Section \(i)\r\n\r\nParagraph \(i) with some **bold** text.\r\n"
        }
        let old = sections.joined(separator: "\r\n")
        let new = old.replacingOccurrences(of: "Paragraph 1500 with", with: "Paragraph 1500 EDITED with")
        #expect(old.utf8.count > 100_000)

        let oldBlocks = MarkdownParser.parse(old)
        let start = CFAbsoluteTimeGetCurrent()
        let actual = MarkdownParser.reparseIncremental(oldText: old, newText: new, oldBlocks: oldBlocks)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let expected = MarkdownParser.parse(new)
        #expect(actual.map(\.id) == expected.map(\.id))
        #expect(actual.map(\.kind) == expected.map(\.kind))
        // A full reparse of this size is easily >1ms; staying well under
        // the incremental-reparse budget is an indirect signal the fast
        // (splice) path was taken rather than a full-reparse fallback.
        #expect(elapsed < 0.05, "CRLF incremental reparse took \(elapsed)s, budget is 50ms")
    }
}
