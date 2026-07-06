import Foundation

/// Pure helpers mapping between a block-list position and a body-relative
/// line number, used by the M3 editor mode transition (PLAN §2 J4) to
/// preserve scroll/caret position across reading ↔ source crossfades
/// without any AppKit/SwiftUI dependency.
public enum BlockPosition {
    /// The index of the last block whose `startLine` is `<= line` (i.e. the
    /// block that "owns" that line). Blocks are assumed sorted by
    /// `startLine` ascending (true of any `[Block]` produced by
    /// `MarkdownParser`/`reparseIncremental`), so this is a binary search.
    /// Blocks with `startLine == -1` (the synthesized frontmatter block)
    /// are skipped since they don't correspond to a real body line.
    /// Returns `nil` for an empty list.
    public static func blockIndex(forLine line: Int, in blocks: [Block]) -> Int? {
        var result: Int?
        var low = 0
        var high = blocks.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let candidate = blocks[mid].startLine
            if candidate == -1 {
                // Frontmatter is always first when present; a target line
                // is never "owned" by it, so just move past.
                low = mid + 1
                continue
            }
            if candidate <= line {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// The body-relative line a block starts on, for scrolling the source
    /// editor to a block that was at the top of the reading viewport.
    /// `nil` for the synthesized frontmatter block (`startLine == -1`).
    public static func startLine(of block: Block) -> Int? {
        block.startLine >= 0 ? block.startLine : nil
    }
}
