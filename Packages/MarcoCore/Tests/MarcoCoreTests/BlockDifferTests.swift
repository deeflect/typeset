import Testing
@testable import MarcoCore

struct BlockDifferTests {

    private func makeDocument(paragraphCount: Int, editing index: Int? = nil) -> String {
        (0..<paragraphCount).map { i in
            if let index, i == index {
                return "Paragraph \(i) EDITED."
            }
            return "Paragraph \(i)."
        }.joined(separator: "\n\n")
    }

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
}
