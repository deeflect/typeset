import Foundation

extension MarkdownParser {

    /// Reparses only the region of `newText` affected by an edit, reusing
    /// unaffected blocks from `oldBlocks` (the result of a prior
    /// `parse(oldText)`) instead of re-running cmark over the whole
    /// document. Result is defined to always equal `parse(newText)` —
    /// when that can't be guaranteed cheaply (an edit touching
    /// frontmatter, any block lacking source-line info, or a reparsed
    /// window that doesn't verifiably resync with the old structure),
    /// this falls back to a full `parse(newText)`.
    ///
    /// Algorithm: find the longest common leading/trailing *lines*
    /// between `oldText`'s body and `newText`'s body, use `oldBlocks`'
    /// own `startLine`s (i.e. cmark's own top-level block boundaries from
    /// the previous parse — not a re-derived heuristic) to find a
    /// candidate run of blocks that could possibly overlap the changed
    /// lines, reparse *that* slice of `newText` plus a small margin of
    /// trailing untouched blocks, and verify (by content hash) that the
    /// reparsed margin matches the untouched blocks it's supposed to
    /// stand in for before trusting the cut. That verification is what
    /// makes this safe across fences/lists/blockquotes without having to
    /// re-derive cmark's own container-block rules: an edit that changes
    /// how far a construct (an unclosed fence, a list absorbing a
    /// continuation line, ...) actually extends will make the margin fail
    /// to verify, and this falls back rather than risk silently wrong
    /// output.
    ///
    /// - Precondition: `oldBlocks` must be (behaviorally) the result of
    ///   `parse(oldText)`. Passing mismatched inputs won't crash, but the
    ///   correctness guarantee above no longer holds.
    public static func reparseIncremental(oldText: String, newText: String, oldBlocks: [Block]) -> [Block] {
        if oldText == newText { return oldBlocks }

        let (oldFrontmatter, oldBody) = splitFrontmatter(oldText)
        let (newFrontmatter, newBody) = splitFrontmatter(newText)

        // Frontmatter changes are rare during live-reload body edits and
        // the line accounting below assumes frontmatter is stable; falling
        // all the way back is simplest and always correct.
        guard oldFrontmatter == newFrontmatter else {
            return parse(newText)
        }

        var oldBodyBlocks = oldBlocks
        if oldFrontmatter != nil {
            oldBodyBlocks.removeFirst()
        }

        // A `startLine` of -1 means cmark/swift-markdown couldn't report a
        // source range for that block (a rare edge case unrelated to
        // incremental reparse); without a position we can't safely map
        // byte ranges to block indices, so fall back.
        guard !oldBodyBlocks.isEmpty, oldBodyBlocks.allSatisfy({ $0.startLine >= 0 }) else {
            return parse(newText)
        }
        guard oldBody != newBody else { return oldBlocks }

        let ordinalOffset = oldFrontmatter != nil ? 1 : 0
        let oldBodyLines = oldBody.split(separator: "\n", omittingEmptySubsequences: false)
        let newBodyLines = newBody.split(separator: "\n", omittingEmptySubsequences: false)

        // Longest common leading run of lines.
        var commonPrefixLines = 0
        let maxPrefix = min(oldBodyLines.count, newBodyLines.count)
        while commonPrefixLines < maxPrefix && oldBodyLines[commonPrefixLines] == newBodyLines[commonPrefixLines] {
            commonPrefixLines += 1
        }

        // Longest common trailing run of lines, not overlapping the prefix.
        var commonSuffixLines = 0
        let maxSuffix = maxPrefix - commonPrefixLines
        while commonSuffixLines < maxSuffix
            && oldBodyLines[oldBodyLines.count - 1 - commonSuffixLines]
                == newBodyLines[newBodyLines.count - 1 - commonSuffixLines] {
            commonSuffixLines += 1
        }

        let prefixBoundaryLine = commonPrefixLines
        let suffixBoundaryLine = oldBodyLines.count - commonSuffixLines

        // j: last block that starts at or before the first changed line —
        // everything before it is untouched; it (and everything after) is
        // a *candidate* for re-derivation.
        guard let j = lastIndex(of: oldBodyBlocks, withStartLineLessThanOrEqualTo: prefixBoundaryLine) else {
            return parse(newText)
        }
        let reparseStartLine = oldBodyBlocks[j].startLine

        // kMin: first block after j that starts at/after the last changed
        // line and is preceded by a blank separator line confirmed to lie
        // entirely within the untouched suffix.
        var kMin = j + 1
        while kMin < oldBodyBlocks.count {
            let startLine = oldBodyBlocks[kMin].startLine
            let separatorLine = startLine - 1
            let separatorIsConfirmedUnchanged = separatorLine >= suffixBoundaryLine
            let separatorIsBlank = separatorLine >= 0 && separatorLine < oldBodyLines.count
                && oldBodyLines[separatorLine].allSatisfy { $0 == " " || $0 == "\t" }
            if startLine >= suffixBoundaryLine && separatorIsConfirmedUnchanged && separatorIsBlank {
                break
            }
            kMin += 1
        }

        // Try increasingly large margins of extra, supposedly-untouched
        // trailing blocks past kMin, reparsing through each and checking
        // that the tail of the reparse verifiably matches (by content
        // hash) the old blocks it's meant to replace 1:1. The first margin
        // that verifies wins; if none do, fall back to a full reparse
        // rather than guess. Margin must be >= 1 whenever kMin isn't
        // already the true end: a margin of 0 gives an empty, vacuously
        // "verified" tail, which would hide exactly the kind of boundary
        // bug (e.g. an edit turning a closing fence into ordinary text)
        // this check exists to catch.
        for margin in [1, 8, 64, oldBodyBlocks.count] {
            let kExt = min(kMin + margin, oldBodyBlocks.count)

            let reparseEndLineNew: Int
            if kExt < oldBodyBlocks.count {
                let linesFromEndOld = oldBodyLines.count - oldBodyBlocks[kExt].startLine
                reparseEndLineNew = newBodyLines.count - linesFromEndOld
            } else {
                reparseEndLineNew = newBodyLines.count
            }
            guard reparseStartLine <= reparseEndLineNew else { continue }

            let sliceText = newBodyLines[reparseStartLine..<reparseEndLineNew].joined(separator: "\n")
            let reparsed = parseBody(sliceText, startOrdinal: j + ordinalOffset, lineOffset: reparseStartLine)

            // swift-markdown occasionally can't report a source range for
            // a node (rare, context-sensitive edge case unrelated to
            // incremental reparse itself); when that happens we can't
            // trust this window's line accounting, so try a larger margin
            // instead of risking a mismatch against a full reparse.
            guard reparsed.allSatisfy({ $0.startLine >= 0 }) else { continue }

            // `effectiveK` is where the *kept, untouched* old-block suffix
            // actually starts for this candidate: `kMin` once the margin
            // verifies (finalReplacement covers [j, kMin)), or `kExt`
            // itself when kExt has grown all the way to the true end (no
            // old suffix left at all — using `kMin` there would splice in
            // oldBodyBlocks[kMin..<kExt] a second time on top of content
            // `reparsed` already covers).
            let finalReplacement: [Block]
            let effectiveK: Int
            if kExt < oldBodyBlocks.count {
                // Verify the tail of `reparsed` (standing in for
                // oldBodyBlocks[kMin..<kExt]) matches those old blocks
                // exactly before trusting this cut.
                let marginOld = oldBodyBlocks[kMin..<kExt]
                guard reparsed.count >= marginOld.count else { continue }
                let tail = reparsed.suffix(marginOld.count)
                let verified = zip(tail, marginOld).allSatisfy { $0.digest == $1.digest && $0.kind == $1.kind }
                guard verified else { continue }
                finalReplacement = Array(reparsed.dropLast(marginOld.count))
                effectiveK = kMin
            } else {
                finalReplacement = reparsed
                effectiveK = kExt
            }

            return spliceResult(
                oldFrontmatter: oldFrontmatter,
                oldBodyBlocks: oldBodyBlocks,
                prefixEnd: j,
                suffixStart: effectiveK,
                replacement: finalReplacement,
                lineDelta: newBodyLines.count - oldBodyLines.count
            )
        }

        return parse(newText)
    }

    private static func spliceResult(
        oldFrontmatter: String?,
        oldBodyBlocks: [Block],
        prefixEnd j: Int,
        suffixStart kMin: Int,
        replacement: [Block],
        lineDelta: Int
    ) -> [Block] {
        let ordinalDelta = (j + replacement.count) - kMin

        var result: [Block] = []
        result.reserveCapacity(oldBodyBlocks.count + ordinalDelta + 1)
        if let oldFrontmatter {
            result.append(Block(kind: .frontmatter, rawText: oldFrontmatter, ordinal: 0, startLine: -1))
        }
        result.append(contentsOf: oldBodyBlocks[0..<j])
        result.append(contentsOf: replacement)
        for block in oldBodyBlocks[kMin...] {
            result.append(
                Block(
                    kind: block.kind,
                    rawText: block.rawText,
                    digest: block.digest,
                    ordinal: block.ordinal + ordinalDelta,
                    startLine: block.startLine + lineDelta
                )
            )
        }
        return result
    }

    /// Binary search: the last index whose `startLine` is `<= line`, or
    /// `nil` if every block starts after `line` (blocks are ordered by
    /// increasing `startLine` since they come from a single top-to-bottom
    /// parse).
    private static func lastIndex(of blocks: [Block], withStartLineLessThanOrEqualTo line: Int) -> Int? {
        var low = 0
        var high = blocks.count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if blocks[mid].startLine <= line {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}
