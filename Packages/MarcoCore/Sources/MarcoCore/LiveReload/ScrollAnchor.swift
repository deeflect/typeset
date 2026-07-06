import Foundation

/// Picks the block to re-anchor scroll position to after a live reload, so
/// applying a `BlockDiffer` diff doesn't visually move content already on
/// screen (PLAN §2 J2: "scroll position anchors to the nearest stable
/// heading, not byte offset").
public enum ScrollAnchor {

    /// - Parameters:
    ///   - oldBlocks: the block list the viewport was showing before reload.
    ///   - changes: `BlockDiffer.diff(old: oldBlocks, new: newBlocks)`.
    ///   - anchorIndex: index, into `oldBlocks`, of the block the viewport
    ///     was anchored to before the reload (e.g. the topmost visible
    ///     block, or the block nearest the viewport's vertical midpoint).
    ///   - headingWindow: how many positions above the nearest unchanged
    ///     block to look for a heading to prefer instead (PLAN calls out
    ///     headings specifically; "nearest stable block" is the fallback).
    /// - Returns: the `Block.id` (valid in both `oldBlocks` and the new
    ///   block list, since it names an `.unchanged` block) to scroll to, or
    ///   `nil` if no unchanged block exists near `anchorIndex` (e.g. the
    ///   entire visible region was replaced) — the caller should leave
    ///   scroll position alone in that case rather than guess.
    public static func selectAnchor(
        oldBlocks: [Block],
        changes: [BlockChange],
        anchorIndex: Int,
        headingWindow: Int = 2
    ) -> String? {
        guard oldBlocks.indices.contains(anchorIndex) else { return nil }

        var unchangedIDs: Set<String> = []
        var headingIDs: Set<String> = []
        for change in changes {
            guard case .unchanged(let block) = change else { continue }
            unchangedIDs.insert(block.id)
            if case .heading = block.kind { headingIDs.insert(block.id) }
        }
        guard !unchangedIDs.isEmpty else { return nil }

        // Search outward from anchorIndex: upward first (so content below
        // the chosen anchor — which may have shifted — never has to move
        // the viewport down past where the user was looking), then
        // downward if nothing unchanged exists above.
        var bestIndex: Int?
        var index = anchorIndex
        while index >= 0 {
            if unchangedIDs.contains(oldBlocks[index].id) { bestIndex = index; break }
            index -= 1
        }
        if bestIndex == nil {
            index = anchorIndex + 1
            while index < oldBlocks.count {
                if unchangedIDs.contains(oldBlocks[index].id) { bestIndex = index; break }
                index += 1
            }
        }
        guard let bestIndex else { return nil }

        // Prefer a heading within `headingWindow` positions above the
        // nearest unchanged block — headings make a better, more
        // recognizable anchor than an arbitrary paragraph.
        var headingSearch = bestIndex
        let floor = max(0, bestIndex - headingWindow)
        while headingSearch >= floor {
            let id = oldBlocks[headingSearch].id
            if headingIDs.contains(id) { return id }
            headingSearch -= 1
        }
        return oldBlocks[bestIndex].id
    }
}
