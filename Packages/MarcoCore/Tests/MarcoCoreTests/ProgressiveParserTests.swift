import Foundation
import Testing
@testable import MarcoCore

struct ProgressiveParserTests {

    private func makeDocument(sectionCount: Int) -> String {
        (0..<sectionCount).map { i in
            """
            ## Section \(i)

            Paragraph \(i) with some **bold** text.

            ```swift
            let value_\(i) = \(i)
            ```

            - [ ] task \(i)
            - [x] task \(i + 1)
            """
        }.joined(separator: "\n\n")
    }

    @Test func progressiveParseYieldsSameBlocksAsFullParse() async {
        let text = makeDocument(sectionCount: 500)
        let expected = MarkdownParser.parse(text)

        var collected: [Block] = []
        for await chunk in MarkdownParser.parseProgressive(text, firstChunkBytes: 5_000) {
            collected.append(contentsOf: chunk)
        }

        #expect(collected.map(\.id) == expected.map(\.id))
        #expect(collected.map(\.kind) == expected.map(\.kind))
        #expect(collected.map(\.rawText) == expected.map(\.rawText))
    }

    @Test func progressiveParsePreservesFrontmatter() async {
        let text = """
        ---
        title: Hello
        ---
        # Heading

        \(makeDocument(sectionCount: 50))
        """
        let expected = MarkdownParser.parse(text)

        var collected: [Block] = []
        for await chunk in MarkdownParser.parseProgressive(text, firstChunkBytes: 2_000) {
            collected.append(contentsOf: chunk)
        }

        #expect(collected.map(\.id) == expected.map(\.id))
        #expect(collected.first?.kind == .frontmatter)
    }

    @Test func progressiveParseYieldsMultipleChunksForALargeDocument() async {
        let text = makeDocument(sectionCount: 500)
        var chunkCount = 0
        for await _ in MarkdownParser.parseProgressive(text, firstChunkBytes: 5_000) {
            chunkCount += 1
        }
        #expect(chunkCount > 1)
    }

    @Test func firstChunkArrivesWellUnderTheTimeToFirstBlocksBudget() async {
        // Budget: time-to-first-blocks < 300 ms even on a 10 MB document.
        // This fixture is smaller (fast, deterministic CI), but exercises
        // the same "don't wait for the whole document" code path.
        let text = makeDocument(sectionCount: 2_000)
        let start = CFAbsoluteTimeGetCurrent()
        var firstChunkElapsed = CFAbsoluteTime.infinity
        for await _ in MarkdownParser.parseProgressive(text, firstChunkBytes: 100_000) {
            firstChunkElapsed = CFAbsoluteTimeGetCurrent() - start
            break
        }
        #expect(firstChunkElapsed < 0.3)
    }

    @Test func chunkBoundariesNeverSplitInsideAFence() {
        let fenceBody = """
        Paragraph one.

        ```swift
        let a = 1

        let b = 2
        ```

        Paragraph two.
        """
        let ranges = MarkdownParser.chunkBoundaries(of: fenceBody, targetChunkBytes: 10)
        for range in ranges {
            let chunk = String(fenceBody[range])
            let fenceMarkerCount = chunk.components(separatedBy: "```").count - 1
            #expect(fenceMarkerCount % 2 == 0, "chunk split inside a fence: \(chunk)")
        }
        // Rejoining every chunk must reproduce the original body exactly.
        let rejoined = ranges.map { String(fenceBody[$0]) }.joined()
        #expect(rejoined == fenceBody)
    }
}
