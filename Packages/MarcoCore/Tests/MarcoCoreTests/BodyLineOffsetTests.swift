import Testing
@testable import MarcoCore

@Suite("bodyLineOffset")
struct BodyLineOffsetTests {
    @Test func noFrontmatterIsZero() {
        #expect(MarkdownParser.bodyLineOffset(in: "# Title\n\nBody.\n") == 0)
    }

    @Test func countsFrontmatterLines() {
        let text = "---\ntitle: X\nauthor: Y\n---\nBody.\n"
        // "---", "title: X", "author: Y", "---" == 4 lines.
        #expect(MarkdownParser.bodyLineOffset(in: text) == 4)
    }

    @Test func nonFrontmatterLeadingThematicBreakIsZero() {
        let text = "---\n\nJust a doc starting with a rule.\n"
        #expect(MarkdownParser.bodyLineOffset(in: text) == 0)
    }
}
