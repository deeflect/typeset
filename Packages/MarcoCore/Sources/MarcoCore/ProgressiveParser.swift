import Foundation

extension MarkdownParser {

    /// Parses `text` progressively instead of all at once: the document is
    /// split into chunks at safe top-level boundaries, the first chunk
    /// (~`firstChunkBytes`, default 100 KB) is parsed and yielded first,
    /// and the rest continue in the background — so a 10 MB file can
    /// still get its first screenful of blocks on screen in well under
    /// 300 ms while the remainder keeps parsing.
    ///
    /// Each element the stream yields is a batch of *new* blocks to
    /// **append** to whatever has already been rendered (not a full
    /// replacement) — ordinals and `startLine`s are continuous across
    /// chunks, exactly as if the whole document had been parsed in one
    /// call to `parse(_:)`.
    ///
    /// Split points are blank lines outside fenced code blocks (a blank
    /// line inside a ``` / ~~~ fence never counts, and a fence is never
    /// split mid-block). This intentionally does *not* reason about list
    /// or blockquote continuation across a blank line the way
    /// `reparseIncremental` does — for a first-render fast path an
    /// occasional list/blockquote getting cut slightly early (i.e. split
    /// into two adjacent top-level chunks that cmark still parses
    /// correctly as separate blocks, just not merged into one loose
    /// list) is a cosmetic-only difference, not a correctness one, since
    /// each chunk is still parsed as valid, self-contained Markdown.
    public static func parseProgressive(_ text: String, firstChunkBytes: Int = 100_000) -> AsyncStream<[Block]> {
        AsyncStream { continuation in
            Task.detached(priority: .userInitiated) {
                let text = normalizingLineEndings(text)
                let (frontmatter, body) = splitFrontmatter(text)
                var ordinal = 0
                // Occurrence indices (see `Block.assigningOccurrenceIndices`)
                // are threaded through as a running per-hash counter across
                // chunks, in document order — equivalent to computing them
                // over the whole concatenated result in one pass, but
                // without needing the whole document parsed upfront.
                var occurrenceCounts: [SIMD32<UInt8>: Int] = [:]
                func withOccurrenceIndices(_ blocks: [Block]) -> [Block] {
                    blocks.map { block in
                        let index = occurrenceCounts[block.digest, default: 0]
                        occurrenceCounts[block.digest] = index + 1
                        return Block(
                            kind: block.kind, rawText: block.rawText, digest: block.digest,
                            ordinal: block.ordinal, startLine: block.startLine, occurrenceIndex: index
                        )
                    }
                }

                if let frontmatter {
                    continuation.yield(withOccurrenceIndices([
                        Block(kind: .frontmatter, rawText: frontmatter, ordinal: ordinal, startLine: -1)
                    ]))
                    ordinal += 1
                }

                let chunkRanges = chunkBoundaries(of: body, targetChunkBytes: firstChunkBytes)
                var lineOffset = 0
                for range in chunkRanges {
                    let slice = body[range]
                    let blocks = parseBody(slice, startOrdinal: ordinal, lineOffset: lineOffset)
                    ordinal += blocks.count
                    lineOffset += slice.lazy.filter { $0 == "\n" }.count
                    continuation.yield(withOccurrenceIndices(blocks))
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Chunk boundaries

    /// Splits `body` into byte-ranges of roughly `targetChunkBytes` each,
    /// cutting only at blank lines that fall outside a fenced code block.
    /// The last chunk absorbs any remainder, and a single block larger
    /// than `targetChunkBytes` (e.g. one huge fenced code block) simply
    /// produces one oversized chunk rather than splitting unsafely.
    static func chunkBoundaries(of body: String, targetChunkBytes: Int) -> [Range<String.Index>] {
        guard !body.isEmpty else { return [] }

        var ranges: [Range<String.Index>] = []
        var chunkStart = body.startIndex
        var bytesSinceChunkStart = 0
        var lastSafeBoundary: String.Index?
        var fenceChar: Character?
        var fenceLength = 0

        var idx = body.startIndex
        while idx < body.endIndex {
            let newlineIndex = body[idx...].firstIndex(of: "\n")
            let lineEnd = newlineIndex.map { body.index(after: $0) } ?? body.endIndex
            let line = body[idx..<lineEnd]
            bytesSinceChunkStart += line.utf8.count

            // Up to 3 leading spaces are allowed before a fence marker or
            // blank-line whitespace per CommonMark; beyond that this is a
            // conservative approximation, not a full CommonMark indentation
            // model.
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            let isBlank = trimmed.allSatisfy { $0 == "\n" }

            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let run = trimmed.prefix { $0 == marker }
                let runLength = run.count
                if runLength >= 3 {
                    // A closing fence line must be *only* the run (plus
                    // trailing whitespace) — "``` foo" after an open
                    // fence is still code content, not a closer.
                    let isCloserShape = trimmed[run.endIndex...].allSatisfy { $0 == " " || $0 == "\t" || $0 == "\n" }
                    if let openChar = fenceChar {
                        if openChar == marker && runLength >= fenceLength && isCloserShape {
                            fenceChar = nil
                            fenceLength = 0
                        }
                    } else {
                        fenceChar = marker
                        fenceLength = runLength
                    }
                }
            }

            if fenceChar == nil && isBlank {
                lastSafeBoundary = lineEnd
            }

            if bytesSinceChunkStart >= targetChunkBytes,
                let boundary = lastSafeBoundary, boundary > chunkStart {
                ranges.append(chunkStart..<boundary)
                chunkStart = boundary
                bytesSinceChunkStart = 0
                lastSafeBoundary = nil
            }

            idx = lineEnd
        }

        if chunkStart < body.endIndex {
            ranges.append(chunkStart..<body.endIndex)
        }
        return ranges
    }
}
