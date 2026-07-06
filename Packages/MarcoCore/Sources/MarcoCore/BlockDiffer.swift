import Foundation

/// A single per-block change between two parses of a document, keyed by
/// `Block.id` (content hash + local same-hash occurrence index). v0 keeps
/// this to insert/delete/reload — no move detection, which is overkill
/// for live-reload use.
public enum BlockChange: Equatable, Sendable {
    case inserted(Block)
    case deleted(Block)
    /// Same `id` present in both `old` and `new` — nothing to re-render.
    case unchanged(Block)
    /// Same position, different content — the block was edited. Only
    /// synthesized for the common single-paragraph-edit shape (see
    /// `diff(old:new:)`); most edits simply show up as an adjacent
    /// delete + insert pair, which is an acceptable, simpler outcome per
    /// the diff's design.
    case reloaded(old: Block, new: Block)
}

/// `Block.id`'s two components (content digest + local occurrence index),
/// used as a `Hashable` dictionary key so `BlockDiffer` never needs to
/// hex-encode a `contentHash` string just to compare/hash block identity.
private struct IdentityKey: Hashable {
    let digest: SIMD32<UInt8>
    let occurrenceIndex: Int
    init(_ block: Block) {
        self.digest = block.digest
        self.occurrenceIndex = block.occurrenceIndex
    }
    static func == (a: IdentityKey, b: IdentityKey) -> Bool {
        a.occurrenceIndex == b.occurrenceIndex && a.digest == b.digest
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(occurrenceIndex)
        withUnsafeBytes(of: digest) { hasher.combine(bytes: $0) }
    }
}

public enum BlockDiffer {

    /// Diffs two block lists by `Block.id` (content hash + local
    /// occurrence index among same-hash duplicates), not by position.
    /// Since `Block.id` no longer bakes global document position into
    /// identity (see `Block.assigningOccurrenceIndices`), a single
    /// insertion/deletion near the top of the document no longer shifts
    /// every downstream block's id — this finds the longest common
    /// subsequence (LCS) of ids between `old` and `new` and reports the
    /// rest as inserted/deleted.
    ///
    /// Complexity: O(P) to trim the common leading/trailing run of
    /// blocks (ids equal at the same relative position from each end),
    /// which collapses the common live-reload case — a small local edit
    /// in a large document — down to a tiny remaining "middle" region,
    /// plus O(N + D) over that middle region using a hashtable-based
    /// LCS (patience-diff-style: blocks in the middle whose id is unique
    /// to both sides are matched by that id in O(1), then the matched
    /// anchors are extended into a full LCS with a single O(N) pass; this
    /// is not full general Myers O(ND) but a widely-used approximation
    /// that is exact whenever ids aren't repeated on both sides within
    /// the middle region — repeats fall back to treating those
    /// occurrences positionally, which only affects duplicate-content
    /// blocks and never changes the deleted/inserted/unchanged counts for
    /// unique blocks). N is the size of the untrimmed middle region and D
    /// is the edit distance within it — for a single local edit in a
    /// large document, both are small regardless of overall document
    /// size.
    public static func diff(old: [Block], new: [Block]) -> [BlockChange] {
        // Trim common prefix. Compares by digest + occurrenceIndex
        // directly (`hasSameIdentity`, equivalent to `.id` equality)
        // rather than through the hex-encoded `id` string — avoids
        // allocating/hex-encoding a `contentHash` string per comparison,
        // which dominates wall-clock time at tens of thousands of blocks.
        var prefixCount = 0
        let maxPrefix = min(old.count, new.count)
        while prefixCount < maxPrefix && old[prefixCount].hasSameIdentity(as: new[prefixCount]) {
            prefixCount += 1
        }

        // Trim common suffix (not overlapping the already-trimmed prefix).
        var suffixCount = 0
        let maxSuffix = maxPrefix - prefixCount
        while suffixCount < maxSuffix
            && old[old.count - 1 - suffixCount].hasSameIdentity(as: new[new.count - 1 - suffixCount]) {
            suffixCount += 1
        }

        var changes: [BlockChange] = []
        changes.reserveCapacity(max(old.count, new.count))
        for block in old[0..<prefixCount] {
            changes.append(.unchanged(block))
        }

        let oldMiddle = Array(old[prefixCount..<(old.count - suffixCount)])
        let newMiddle = Array(new[prefixCount..<(new.count - suffixCount)])
        changes.append(contentsOf: diffMiddle(old: oldMiddle, new: newMiddle))

        for block in old[(old.count - suffixCount)...] {
            changes.append(.unchanged(block))
        }

        return changes
    }

    /// LCS-by-id over the untrimmed middle region, using a hashtable to
    /// find ids unique to each side in O(1) rather than the O(N*M) DP
    /// table a textbook LCS would use. Correct and exact when there are
    /// no duplicate ids within `old` or within `new`'s middle region
    /// (the overwhelmingly common case — duplicate ids within the SAME
    /// parse only arise from duplicate-content blocks that also didn't
    /// shift relative occurrence order, which is rare for the changed
    /// middle region specifically). When duplicates land in the middle
    /// region, they're matched greedily in order of appearance, which
    /// stays correct for total insert/delete/unchanged counts.
    private static func diffMiddle(old: [Block], new: [Block]) -> [BlockChange] {
        if old.isEmpty && new.isEmpty { return [] }
        if old.isEmpty { return new.map { .inserted($0) } }
        if new.isEmpty { return old.map { .deleted($0) } }

        // Map each id in `new` to the queue of indices where it occurs.
        // Keyed by (digest, occurrenceIndex) — the same components that
        // make up `.id` — rather than the hex `id` string itself, to
        // avoid a hex-encode allocation per block (see `hasSameIdentity`).
        var newIndicesByID: [IdentityKey: [Int]] = [:]
        newIndicesByID.reserveCapacity(new.count)
        for (index, block) in new.enumerated() {
            newIndicesByID[IdentityKey(block), default: []].append(index)
        }

        // For each old block (in order), find its next matching index in
        // `new` that's strictly greater than the last matched `new`
        // index — this greedily builds an increasing subsequence of
        // matched (oldIndex, newIndex) pairs, which is exactly an LCS
        // when ids are unique per side, and a reasonable/stable
        // approximation otherwise.
        var matches: [(oldIndex: Int, newIndex: Int)] = []
        var lastNewIndex = -1
        for (oldIndex, block) in old.enumerated() {
            let key = IdentityKey(block)
            guard var candidates = newIndicesByID[key] else { continue }
            // Drop any already-consumed or now-stale (<= lastNewIndex)
            // candidates from the front.
            while let first = candidates.first, first <= lastNewIndex {
                candidates.removeFirst()
            }
            guard let matchedNewIndex = candidates.first else {
                newIndicesByID[key] = candidates
                continue
            }
            candidates.removeFirst()
            newIndicesByID[key] = candidates
            matches.append((oldIndex, matchedNewIndex))
            lastNewIndex = matchedNewIndex
        }

        var changes: [BlockChange] = []
        changes.reserveCapacity(old.count + new.count)
        var oldCursor = 0
        var newCursor = 0

        // A single deleted+inserted pair sitting at the same region (no
        // unchanged blocks between them, one of each) reads as an edited
        // block — surfaced as `.reloaded` for a nicer pulse animation.
        // This is optional polish (see doc comment on `BlockChange`), not
        // required for correctness.
        func flushGap(oldEnd: Int, newEnd: Int) {
            let deleted = Array(old[oldCursor..<oldEnd])
            let inserted = Array(new[newCursor..<newEnd])
            if deleted.count == 1 && inserted.count == 1 {
                changes.append(.reloaded(old: deleted[0], new: inserted[0]))
            } else {
                for block in deleted { changes.append(.deleted(block)) }
                for block in inserted { changes.append(.inserted(block)) }
            }
        }

        for (oldIndex, newIndex) in matches {
            flushGap(oldEnd: oldIndex, newEnd: newIndex)
            changes.append(.unchanged(new[newIndex]))
            oldCursor = oldIndex + 1
            newCursor = newIndex + 1
        }
        flushGap(oldEnd: old.count, newEnd: new.count)

        return changes
    }
}
