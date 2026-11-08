import Foundation
import Testing
@testable import TypesetCore

struct FrontmatterMetadataTests {

    @Test func blogPost() throws {
        let entries = try #require(FrontmatterMetadata.entries("""
        ---
        title: "Shipping Typeset: a reader"
        date: 2026-11-05
        draft: false
        weight: 1.10
        tags: [swift, 'mac os', markdown]
        authors:
          - Dee
          - "Ada L."
        summary: >
          Folded
          text
        # a comment
        ---
        """))
        #expect(entries.map(\.key) == ["title", "date", "draft", "weight", "tags", "authors", "summary"])
        #expect(entries[0].value == .string("Shipping Typeset: a reader"))
        guard case .date(let date, let text) = entries[1].value else { Issue.record("date"); return }
        #expect(text == "2026-11-05")
        #expect(date == ISO8601DateFormatter().date(from: "2026-11-05T00:00:00Z"))
        #expect(entries[2].value == .bool(false))
        #expect(entries[3].value == .number(1.1, text: "1.10"))
        #expect(entries[4].value == .list(["swift", "mac os", "markdown"]))
        #expect(entries[5].value == .list(["Dee", "Ada L."]))
        #expect(entries[6].value == .string("Folded text"))
    }

    @Test func claudeCodeAgent() throws {
        let entries = try #require(FrontmatterMetadata.entries("""
        name: code-reviewer
        description: Reviews diffs. Use PROACTIVELY after edits: it checks correctness.
        model: opus
        tools: Read, Grep, Glob
        updated: 2026-11-05T10:30:00Z
        """))
        #expect(entries.map(\.key) == ["name", "description", "model", "tools", "updated"])
        #expect(entries[1].value == .string("Reviews diffs. Use PROACTIVELY after edits: it checks correctness."))
        #expect(entries[3].value == .string("Read, Grep, Glob"))
        guard case .date(_, let text) = entries[4].value else { Issue.record("datetime"); return }
        #expect(text == "2026-11-05T10:30:00Z")
    }

    @Test func nestedMapIsRaw() throws {
        let entries = try #require(FrontmatterMetadata.entries("""
        title: Doc
        seo:
          title: Other
          keywords:
            - a
        list:
          - name: x
        """))
        #expect(entries[1] == FrontmatterEntry(key: "seo", value: .raw("title: Other\nkeywords:\n  - a")))
        #expect(entries[2].value == .raw("- name: x"))
    }

    @Test func malformedIsNil() {
        #expect(FrontmatterMetadata.entries("just some prose\ntitle: x") == nil)
        #expect(FrontmatterMetadata.entries("title: \"unterminated") == nil)
        #expect(FrontmatterMetadata.entries("tags: [a, b") == nil)
        #expect(FrontmatterMetadata.entries("  indented: first") == nil)
        #expect(FrontmatterMetadata.entries("---\n---") == nil)
    }
}
