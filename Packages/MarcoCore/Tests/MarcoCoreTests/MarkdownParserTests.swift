import Testing
@testable import MarcoCore

struct MarkdownParserTests {

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

    @Test func duplicateContentBlocksGetOrdinalDisambiguatedIdentities() {
        // Two blocks with byte-identical raw text (as could arise from two
        // thematic breaks) must still get distinct stable ids via ordinal.
        let first = Block(kind: .thematicBreak, rawText: "---", ordinal: 0)
        let second = Block(kind: .thematicBreak, rawText: "---", ordinal: 1)
        #expect(first.contentHash == second.contentHash)
        #expect(first.id != second.id)
    }
}
