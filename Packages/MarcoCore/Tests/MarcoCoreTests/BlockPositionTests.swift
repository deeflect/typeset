import Testing
@testable import MarcoCore

@Suite("BlockPosition")
struct BlockPositionTests {
    private func block(startLine: Int, ordinal: Int) -> Block {
        Block(kind: .paragraph, rawText: "text-\(ordinal)", ordinal: ordinal, startLine: startLine)
    }

    @Test func findsExactStartLine() {
        let blocks = [block(startLine: 0, ordinal: 0), block(startLine: 5, ordinal: 1), block(startLine: 12, ordinal: 2)]
        #expect(BlockPosition.blockIndex(forLine: 5, in: blocks) == 1)
    }

    @Test func findsOwningBlockBetweenStarts() {
        let blocks = [block(startLine: 0, ordinal: 0), block(startLine: 5, ordinal: 1), block(startLine: 12, ordinal: 2)]
        #expect(BlockPosition.blockIndex(forLine: 8, in: blocks) == 1)
    }

    @Test func lineBeforeFirstBlockReturnsNil() {
        let blocks = [block(startLine: 3, ordinal: 0)]
        #expect(BlockPosition.blockIndex(forLine: 0, in: blocks) == nil)
    }

    @Test func lineAfterLastBlockReturnsLastBlock() {
        let blocks = [block(startLine: 0, ordinal: 0), block(startLine: 5, ordinal: 1)]
        #expect(BlockPosition.blockIndex(forLine: 100, in: blocks) == 1)
    }

    @Test func skipsFrontmatterBlock() {
        let blocks = [
            Block(kind: .frontmatter, rawText: "---\nx: 1\n---", ordinal: 0, startLine: -1),
            block(startLine: 0, ordinal: 1),
        ]
        #expect(BlockPosition.blockIndex(forLine: 0, in: blocks) == 1)
    }

    @Test func emptyListReturnsNil() {
        #expect(BlockPosition.blockIndex(forLine: 0, in: []) == nil)
    }

    @Test func startLineOfFrontmatterIsNil() {
        let fm = Block(kind: .frontmatter, rawText: "---\nx: 1\n---", ordinal: 0, startLine: -1)
        #expect(BlockPosition.startLine(of: fm) == nil)
    }

    @Test func startLineOfOrdinaryBlock() {
        #expect(BlockPosition.startLine(of: block(startLine: 7, ordinal: 0)) == 7)
    }
}
