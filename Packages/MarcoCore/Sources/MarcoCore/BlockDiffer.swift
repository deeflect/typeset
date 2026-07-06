import Foundation

/// A single per-block change between two parses of a document, keyed by
/// `Block.id` (content hash + ordinal). v0 keeps this to insert/delete/
/// reload — no move detection, which is overkill for live-reload use.
public enum BlockChange: Equatable, Sendable {
    case inserted(Block)
    case deleted(Block)
    /// Same `id` (position + hash) unchanged — nothing to re-render.
    case unchanged(Block)
    /// Same position, different content — the block was edited.
    case reloaded(old: Block, new: Block)
}

public enum BlockDiffer {

    /// Diffs two block lists positionally: index `i` in `old` is compared
    /// to index `i` in `new`. Since `Block.id` already encodes content
    /// hash + ordinal, an edited paragraph changes only its own id and
    /// its own slot — every other block keeps the same id at the same
    /// index, so this stays O(n) and produces exactly one `reloaded`
    /// for a single-paragraph edit.
    public static func diff(old: [Block], new: [Block]) -> [BlockChange] {
        var changes: [BlockChange] = []
        let count = max(old.count, new.count)

        for index in 0..<count {
            switch (index < old.count ? old[index] : nil, index < new.count ? new[index] : nil) {
            case let (oldBlock?, newBlock?):
                if oldBlock.id == newBlock.id {
                    changes.append(.unchanged(newBlock))
                } else {
                    changes.append(.reloaded(old: oldBlock, new: newBlock))
                }
            case let (nil, newBlock?):
                changes.append(.inserted(newBlock))
            case let (oldBlock?, nil):
                changes.append(.deleted(oldBlock))
            case (nil, nil):
                continue
            }
        }

        return changes
    }
}
