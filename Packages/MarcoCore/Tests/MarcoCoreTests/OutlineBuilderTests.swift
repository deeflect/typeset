import Testing
@testable import MarcoCore

struct OutlineBuilderTests {

    @Test func flatOutlineWithNormalizedDepths() {
        let raw = """
        # Title

        ## Section One

        ## Section Two

        ### Subsection

        # Another Title
        """
        let blocks = MarkdownParser.parse(raw)
        let outline = OutlineBuilder.build(from: blocks)

        #expect(outline.count == 5)
        #expect(outline.map(\.title) == ["Title", "Section One", "Section Two", "Subsection", "Another Title"])
        #expect(outline.map(\.level) == [1, 2, 2, 3, 1])
        #expect(outline.map(\.depth) == [0, 1, 1, 2, 0])

        let headingBlocks = blocks.filter {
            if case .heading = $0.kind { return true }
            return false
        }
        #expect(outline.map(\.id) == headingBlocks.map(\.id))
    }

    @Test func headingTextResolvesInlineContentLikeATrailingHash() {
        let raw = "# C#\n\n## **Bold** [linked](other.md) `code`\n"
        let blocks = MarkdownParser.parse(raw)
        let outline = OutlineBuilder.build(from: blocks)
        #expect(outline.map(\.title) == ["C#", "Bold linked code"])
    }

    @Test func skippedLevelDoesNotDoubleIndent() {
        let raw = """
        # Top

        ### Skipped To Three
        """
        let blocks = MarkdownParser.parse(raw)
        let outline = OutlineBuilder.build(from: blocks)
        #expect(outline.map(\.level) == [1, 3])
        #expect(outline.map(\.depth) == [0, 1])
    }
}
