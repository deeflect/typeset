import Foundation
import Testing
@testable import TypesetCore

struct BlockDifferTests {

    private func makeDocument(paragraphCount: Int, editing index: Int? = nil) -> String {
        (0..<paragraphCount).map { i in
            if let index, i == index {
                return "Paragraph \(i) EDITED."
            }
            return "Paragraph \(i)."
        }.joined(separator: "\n\n")
    }

    /// Under the OLD id scheme (contentHash + global ordinal), an edited
    /// block's id changed but every other block's id and POSITION stayed
    /// the same, so this was a positional diff producing exactly one
    /// `.reloaded`. Under the NEW id scheme (contentHash + local
    /// same-hash occurrence index), the edited block's id changes but
    /// every *other* block's id is untouched — the greedy identity diff
    /// still finds the same result here (a single differing block
    /// surrounded by two long common-id runs collapses to exactly one
    /// adjacent delete+insert pair), which `BlockDiffer` optionally
    /// reports as `.reloaded` for a nicer pulse animation. So the
    /// expected counts are unchanged from before, even though the
    /// underlying reasoning (position vs. identity matching) is different.
    @Test func editingOneParagraphIn100BlockDocProducesExactlyOneChange() {
        let oldText = makeDocument(paragraphCount: 100)
        let newText = makeDocument(paragraphCount: 100, editing: 42)

        let oldBlocks = MarkdownParser.parse(oldText)
        let newBlocks = MarkdownParser.parse(newText)
        #expect(oldBlocks.count == 100)
        #expect(newBlocks.count == 100)

        let changes = BlockDiffer.diff(old: oldBlocks, new: newBlocks)
        let reloaded = changes.filter {
            if case .reloaded = $0 { return true }
            return false
        }
        let unchanged = changes.filter {
            if case .unchanged = $0 { return true }
            return false
        }

        #expect(reloaded.count == 1)
        #expect(unchanged.count == 99)
    }

    @Test func identicalDocumentsProduceAllUnchanged() {
        let text = makeDocument(paragraphCount: 10)
        let blocks = MarkdownParser.parse(text)
        let changes = BlockDiffer.diff(old: blocks, new: blocks)
        #expect(changes.allSatisfy {
            if case .unchanged = $0 { return true }
            return false
        })
    }

    @Test func appendingABlockProducesOneInsertion() {
        let oldText = makeDocument(paragraphCount: 5)
        let newText = oldText + "\n\nParagraph 5."

        let oldBlocks = MarkdownParser.parse(oldText)
        let newBlocks = MarkdownParser.parse(newText)
        let changes = BlockDiffer.diff(old: oldBlocks, new: newBlocks)

        let inserted = changes.filter {
            if case .inserted = $0 { return true }
            return false
        }
        #expect(inserted.count == 1)
    }

    @Test func removingATrailingBlockProducesOneDeletion() {
        let oldText = makeDocument(paragraphCount: 5)
        let newText = makeDocument(paragraphCount: 4)

        let oldBlocks = MarkdownParser.parse(oldText)
        let newBlocks = MarkdownParser.parse(newText)
        let changes = BlockDiffer.diff(old: oldBlocks, new: newBlocks)

        let deleted = changes.filter {
            if case .deleted = $0 { return true }
            return false
        }
        #expect(deleted.count == 1)
    }

    @Test func insertingABlockInTheMiddleProducesOneInsertionAndAllOthersUnchanged() {
        let oldText = makeDocument(paragraphCount: 100)
        var paragraphs = (0..<100).map { "Paragraph \($0)." }
        paragraphs.insert("Inserted paragraph.", at: 50)
        let newText = paragraphs.joined(separator: "\n\n")

        let oldBlocks = MarkdownParser.parse(oldText)
        let newBlocks = MarkdownParser.parse(newText)
        #expect(oldBlocks.count == 100)
        #expect(newBlocks.count == 101)

        let changes = BlockDiffer.diff(old: oldBlocks, new: newBlocks)
        let inserted = changes.filter {
            if case .inserted = $0 { return true }
            return false
        }
        let unchanged = changes.filter {
            if case .unchanged = $0 { return true }
            return false
        }

        #expect(inserted.count == 1)
        #expect(unchanged.count == 100)
    }

    @Test func deletingABlockFromTheMiddleProducesOneDeletionAndAllOthersUnchanged() {
        var paragraphs = (0..<100).map { "Paragraph \($0)." }
        let oldText = paragraphs.joined(separator: "\n\n")
        paragraphs.remove(at: 50)
        let newText = paragraphs.joined(separator: "\n\n")

        let oldBlocks = MarkdownParser.parse(oldText)
        let newBlocks = MarkdownParser.parse(newText)
        #expect(oldBlocks.count == 100)
        #expect(newBlocks.count == 99)

        let changes = BlockDiffer.diff(old: oldBlocks, new: newBlocks)
        let deleted = changes.filter {
            if case .deleted = $0 { return true }
            return false
        }
        let unchanged = changes.filter {
            if case .unchanged = $0 { return true }
            return false
        }

        #expect(deleted.count == 1)
        #expect(unchanged.count == 99)
    }

    /// Move detection is explicitly out of scope (see `BlockDiffer.diff`
    /// doc comment): reordering two blocks has no "moved" representation
    /// and shows up as a delete + insert pair instead. This test only
    /// asserts the diff doesn't crash and produces a sane, fully
    /// accounted-for result — not a specific "moved" case.
    @Test func movingABlockProducesASaneResultWithoutCrashing() {
        var paragraphs = (0..<20).map { "Paragraph \($0)." }
        let oldText = paragraphs.joined(separator: "\n\n")
        paragraphs.swapAt(5, 15)
        let newText = paragraphs.joined(separator: "\n\n")

        let oldBlocks = MarkdownParser.parse(oldText)
        let newBlocks = MarkdownParser.parse(newText)
        let changes = BlockDiffer.diff(old: oldBlocks, new: newBlocks)

        // Every old block is accounted for as unchanged or deleted, every
        // new block as unchanged or inserted (reloaded counts as both).
        var deletedOrReloadedOld = 0
        var insertedOrReloadedNew = 0
        var unchangedCount = 0
        for change in changes {
            switch change {
            case .unchanged: unchangedCount += 1
            case .deleted: deletedOrReloadedOld += 1
            case .inserted: insertedOrReloadedNew += 1
            case .reloaded:
                deletedOrReloadedOld += 1
                insertedOrReloadedNew += 1
            }
        }
        #expect(unchangedCount + deletedOrReloadedOld == oldBlocks.count)
        #expect(unchangedCount + insertedOrReloadedNew == newBlocks.count)
    }

    private func makePaddedDocument(paragraphCount: Int, editing index: Int? = nil) -> String {
        (0..<paragraphCount).map { i in
            let suffix = (index == i) ? " EDITED." : "."
            return "Paragraph \(i) with some extra filler text to pad out document size for benchmarking\(suffix)"
        }.joined(separator: "\n\n")
    }

    @Test func oneParagraphEditIn1MBDocumentDiffMeetsThe10msBudget() {
        let oldText = makePaddedDocument(paragraphCount: 12_000)
        #expect(oldText.utf8.count > 1_000_000)
        let newText = makePaddedDocument(paragraphCount: 12_000, editing: 6_000)

        let oldBlocks = MarkdownParser.parse(oldText)
        let newBlocks = MarkdownParser.parse(newText)

        let start = CFAbsoluteTimeGetCurrent()
        let changes = BlockDiffer.diff(old: oldBlocks, new: newBlocks)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let reloaded = changes.filter {
            if case .reloaded = $0 { return true }
            return false
        }
        #expect(reloaded.count == 1)
        #expect(elapsed < 0.01, "diff took \(elapsed)s, budget is 10ms")
    }

    @Test func changesSinceStoredReportsNewBlocksInOrderAndRemovedCount() {
        let before = MarkdownParser.parse("# Title\n\nKeep.\n\nOld.\n\nGone.\n")
        let after = MarkdownParser.parse("# Title\n\nNew first.\n\nKeep.\n\nOld edited.\n")
        let result = BlockDiffer.changesSince(stored: Set(before.map(\.id)), current: after)
        #expect(result.changed == [after[1].id, after[3].id])
        #expect(result.removed == 2)
        #expect(BlockDiffer.changesSince(stored: Set(after.map(\.id)), current: after).changed.isEmpty)
    }
}
