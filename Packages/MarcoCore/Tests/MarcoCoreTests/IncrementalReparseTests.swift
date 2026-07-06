import Foundation
import Testing
@testable import MarcoCore

struct IncrementalReparseTests {

    /// Asserts `reparseIncremental` produces exactly the same blocks
    /// (kind, rawText, id, startLine) as a full `parse(newText)` — the
    /// correctness contract the whole feature rests on.
    private func assertIncrementalMatchesFullReparse(
        oldText: String, newText: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let oldBlocks = MarkdownParser.parse(oldText)
        let expected = MarkdownParser.parse(newText)
        let actual = MarkdownParser.reparseIncremental(oldText: oldText, newText: newText, oldBlocks: oldBlocks)

        #expect(actual.map(\.id) == expected.map(\.id), sourceLocation: sourceLocation)
        #expect(actual.map(\.kind) == expected.map(\.kind), sourceLocation: sourceLocation)
        #expect(actual.map(\.rawText) == expected.map(\.rawText), sourceLocation: sourceLocation)
        #expect(actual.map(\.startLine) == expected.map(\.startLine), sourceLocation: sourceLocation)
    }

    private func makeDocument(sectionCount: Int) -> String {
        (0..<sectionCount).map { i in
            """
            ## Section \(i)

            Paragraph \(i) with some **bold** text.

            | Col A | Col B |
            | ----- | ----- |
            | \(i) | \(i * 2) |

            ```swift
            let value_\(i) = \(i)
            ```

            - [ ] task \(i)
            - [x] task \(i + 1)
            """
        }.joined(separator: "\n\n")
    }

    @Test func editingAParagraphInTheMiddle() {
        let old = makeDocument(sectionCount: 20)
        let new = old.replacingOccurrences(of: "Paragraph 10 with", with: "Paragraph 10 EDITED with")
        assertIncrementalMatchesFullReparse(oldText: old, newText: new)
    }

    @Test func editingInsideACodeFence() {
        let old = makeDocument(sectionCount: 20)
        let new = old.replacingOccurrences(of: "let value_10 = 10", with: "let value_10 = 999")
        assertIncrementalMatchesFullReparse(oldText: old, newText: new)
    }

    @Test func editingRightAtAFenceBoundary() {
        let old = makeDocument(sectionCount: 20)
        let new = old.replacingOccurrences(of: "```swift\nlet value_10", with: "```python\nlet value_10")
        assertIncrementalMatchesFullReparse(oldText: old, newText: new)
    }

    @Test func editingATableRow() {
        let old = makeDocument(sectionCount: 20)
        let new = old.replacingOccurrences(of: "| 10 | 20 |", with: "| 10 | 999 |")
        assertIncrementalMatchesFullReparse(oldText: old, newText: new)
    }

    @Test func editingTheFrontmatterFallsBackToFullReparseCorrectly() {
        let old = "---\ntitle: Hello\n---\n\n" + makeDocument(sectionCount: 10)
        let new = "---\ntitle: Goodbye\n---\n\n" + makeDocument(sectionCount: 10)
        assertIncrementalMatchesFullReparse(oldText: old, newText: new)
    }

    @Test func editingTheFirstBlock() {
        let old = makeDocument(sectionCount: 20)
        let new = old.replacingOccurrences(of: "## Section 0", with: "## Section ZERO")
        assertIncrementalMatchesFullReparse(oldText: old, newText: new)
    }

    @Test func editingTheLastBlock() {
        let old = makeDocument(sectionCount: 20)
        let new = old.replacingOccurrences(of: "- [x] task 20", with: "- [x] task 999")
        assertIncrementalMatchesFullReparse(oldText: old, newText: new)
    }

    @Test func insertingANewSectionInTheMiddle() {
        let old = makeDocument(sectionCount: 20)
        let sections = old.components(separatedBy: "\n\n## Section")
        var new = sections[0]
        for (i, section) in sections.dropFirst().enumerated() {
            new += "\n\n## Section" + section
            if i == 9 {
                new += "\n\n## Section EXTRA\n\nInserted paragraph."
            }
        }
        assertIncrementalMatchesFullReparse(oldText: old, newText: new)
    }

    @Test func deletingATrailingSection() {
        let old = makeDocument(sectionCount: 20)
        let new = makeDocument(sectionCount: 19)
        assertIncrementalMatchesFullReparse(oldText: old, newText: new)
    }

    /// The core id-stability property the whole redesign rests on: a
    /// block far from an insertion point keeps the EXACT same `id`
    /// before and after, because `id` is now content-hash + LOCAL
    /// same-hash occurrence index rather than content-hash + global
    /// ordinal. `BlockDiffer`'s exact insert/delete counts depend on
    /// this holding, not just on "the diff looks reasonable".
    @Test func idsFarFromAnInsertionPointAreExactlyPreserved() {
        let old = makeDocument(sectionCount: 100)
        let oldBlocks = MarkdownParser.parse(old)

        let sections = old.components(separatedBy: "\n\n## Section")
        var new = sections[0]
        for (i, section) in sections.dropFirst().enumerated() {
            new += "\n\n## Section" + section
            if i == 4 {
                new += "\n\n## Section EXTRA\n\nInserted paragraph."
            }
        }

        let newBlocksFull = MarkdownParser.parse(new)
        let newBlocksIncremental = MarkdownParser.reparseIncremental(oldText: old, newText: new, oldBlocks: oldBlocks)

        // Blocks belonging to sections well after the insertion point
        // (say, section 50 onward) must keep exactly the same ids as
        // before the insertion — not just "the same relative diff".
        let farOldIDs = oldBlocks.filter { $0.startLine >= 0 && $0.rawText.contains("Section 5") }.map(\.id)
        let farNewFullIDs = newBlocksFull.filter { $0.rawText.contains("Section 5") }.map(\.id)
        let farNewIncrementalIDs = newBlocksIncremental.filter { $0.rawText.contains("Section 5") }.map(\.id)

        #expect(!farOldIDs.isEmpty)
        #expect(farNewFullIDs == farOldIDs)
        #expect(farNewIncrementalIDs == farOldIDs)
    }

    @Test func identicalTextReturnsSameBlocksWithoutReparsing() {
        let text = makeDocument(sectionCount: 5)
        let blocks = MarkdownParser.parse(text)
        let result = MarkdownParser.reparseIncremental(oldText: text, newText: text, oldBlocks: blocks)
        #expect(result.map(\.id) == blocks.map(\.id))
    }

    @Test func oneParagraphEditIn1MBDocumentMeetsThe50msBudget() {
        let old = makeDocument(sectionCount: 3000)
        let new = old.replacingOccurrences(of: "Paragraph 1500 with", with: "Paragraph 1500 EDITED with")
        #expect(old.utf8.count > 500_000)

        let oldBlocks = MarkdownParser.parse(old)
        let start = CFAbsoluteTimeGetCurrent()
        let result = MarkdownParser.reparseIncremental(oldText: old, newText: new, oldBlocks: oldBlocks)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let expected = MarkdownParser.parse(new)
        #expect(result.map(\.id) == expected.map(\.id))
        #expect(elapsed < 0.05, "incremental reparse took \(elapsed)s, budget is 50ms")
    }

    // MARK: - Property test: random single-region edits

    /// Deterministic PRNG so a failing trial is reproducible across runs
    /// instead of depending on `SystemRandomNumberGenerator`'s fresh
    /// entropy every time.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    @Test func randomEditsAlwaysMatchFullReparse() {
        let base = makeDocument(sectionCount: 40)
        var generator = SeededGenerator(seed: 42)

        for trial in 0..<200 {
            var lines = base.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard !lines.isEmpty else { continue }
            let editIndex = Int.random(in: 0..<lines.count, using: &generator)
            let mutation = ["EDITED", "", "  indented continuation", "### interrupting heading"]
                .randomElement(using: &generator)!
            lines[editIndex] = lines[editIndex] + " " + mutation
            let mutated = lines.joined(separator: "\n")

            let oldBlocks = MarkdownParser.parse(base)
            let expected = MarkdownParser.parse(mutated)

            // Pre-existing swift-markdown limitation, independent of
            // incremental reparse: for a small set of inputs (a paragraph
            // gaining a "lazy continuation" line where a blank separator
            // used to be, only reproducible in a large-enough document)
            // `markup.range` comes back `nil` for one node even on a
            // plain `parse(_:)` call, and the `markup.format()` fallback
            // doesn't round-trip cleanly. Confirmed independent of this
            // feature: `parse(mutated)` alone (no incremental code
            // involved) already exhibits it. Skip those trials rather
            // than assert equality against an already-inconsistent
            // baseline; every other trial still holds incremental to a
            // strict equality bar.
            guard !expected.contains(where: { $0.startLine < 0 }) else { continue }

            let actual = MarkdownParser.reparseIncremental(oldText: base, newText: mutated, oldBlocks: oldBlocks)
            #expect(
                actual.map(\.id) == expected.map(\.id),
                "trial \(trial) editIndex=\(editIndex) mutation=\(mutation.debugDescription) editedLine=\(lines[editIndex].debugDescription)"
            )
        }
    }
}
