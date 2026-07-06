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
                let (frontmatter, body) = splitFrontmatter(text)
                var ordinal = 0
                if let frontmatter {
                    continuation.yield([
                        Block(kind: .frontmatter, rawText: frontmatter, ordinal: ordinal, startLine: -1)
                    ])
                    ordinal += 1
                }

                let chunkRanges = chunkBoundaries(of: body, targetChunkBytes: firstChunkBytes)
                var lineOffset = 0
                for range in chunkRanges {
                    let slice = body[range]
                    let blocks = parseBody(slice, startOrdinal: ordinal, lineOffset: lineOffset)
                    ordinal += blocks.count
                    lineOffset += slice.lazy.filter { $0 == "\n" }.count
                    continuation.yield(blocks)
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
                let runLength = trimmed.prefix { $0 == marker }.count
                if runLength >= 3 {
                    if let openChar = fenceChar {
                        if openChar == marker && runLength >= fenceLength {
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
