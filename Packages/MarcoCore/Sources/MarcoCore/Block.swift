import CryptoKit
import Foundation

/// The kind of a top-level Markdown block, along with any payload the
/// renderer needs that isn't just the raw text (e.g. a code block's
/// language tag).
public enum BlockKind: Equatable, Sendable {
    case frontmatter
    case heading(level: Int)
    case paragraph
    case codeBlock(language: String?)
    case list
    case table
    case blockquote
    case thematicBreak
    case htmlBlock
}

/// A single block-level unit of a parsed Markdown document.
///
/// Identity is `contentHash` (SHA-256 of the block's raw text) plus
/// `occurrenceIndex`, a LOCAL counter scoped to blocks sharing that exact
/// hash: the first block anywhere in the document with a given hash is
/// occurrence 0, the second block anywhere in the document with that same
/// hash is occurrence 1, and so on, counted in document order. Unlike the
/// old scheme (a global position counter baked into every block's id),
/// this means a unique block's `id` never changes just because unrelated
/// blocks were inserted or deleted elsewhere in the document — only
/// genuine duplicates (e.g. repeated `---` thematic breaks) are
/// disambiguated, and only relative to their own duplicate siblings. See
/// `Block.assigningOccurrenceIndices(to:)` for how this is computed.
public struct Block: Identifiable, Equatable, Sendable {
    public let kind: BlockKind
    /// Raw Markdown source text for this block (used for hashing and,
    /// for now, as the plumbing-proof render payload).
    public let rawText: String
    /// 0-based global position counter assigned during parsing. Retained
    /// for internal ordering/splicing (`IncrementalReparse`,
    /// `ProgressiveParser`'s ordinal continuity across chunks) — it is
    /// NOT part of `id` anymore (see `occurrenceIndex`), since baking
    /// global position into identity is exactly what made every
    /// downstream block's `id` change on an unrelated edit.
    public let ordinal: Int
    /// Local occurrence index among blocks sharing this exact
    /// `contentHash`, in document order (0 for the first such block, 1
    /// for the second, ...). This — not `ordinal` — is what disambiguates
    /// duplicate-content blocks in `id`. Defaults to 0; callers that build
    /// a full `[Block]` array should run it through
    /// `Block.assigningOccurrenceIndices(to:)` before treating `id` as
    /// final.
    public let occurrenceIndex: Int
    /// 0-based line number (within the body text that was parsed — i.e.
    /// after frontmatter has been split off) where this block starts.
    /// `-1` for the synthesized frontmatter block, and for blocks created
    /// via the memberwise initializer without an explicit value (kept
    /// `Int` with a default so the public initializer stays source
    /// compatible). Used by `MarkdownParser.reparseIncremental` to map a
    /// changed byte range back onto affected blocks without re-parsing
    /// the whole document.
    public let startLine: Int

    /// The raw SHA-256 digest, stored inline (32 bytes, no heap
    /// allocation) instead of as a 64-character hex `String`. Parsing a
    /// 10 MB document produces ~235k blocks; at one heap-allocated
    /// 64-byte string per block that's ~235k extra long-lived small
    /// allocations, which measured as the dominant contributor to this
    /// type's retained memory (parsing the 10 MB fixture and holding the
    /// result went from ~670 MB RSS to ~140 MB after this change, per
    /// MarcoCoreBenchmark) — well beyond what the ~65 bytes of hex text
    /// itself would suggest, consistent with small-object allocator
    /// overhead/fragmentation at this volume. `contentHash` below
    /// reproduces the exact same hex string on demand. Internal (not
    /// `private`) so `MarkdownParser.reparseIncremental` — a different
    /// file in this module — can reuse an untouched block's digest
    /// directly without a hex round-trip.
    let digest: SIMD32<UInt8>

    /// SHA-256 hex digest of `rawText`, computed on demand from `digest`.
    public var contentHash: String { Block.hex(digest) }

    public init(kind: BlockKind, rawText: String, ordinal: Int, startLine: Int = -1, occurrenceIndex: Int = 0) {
        self.kind = kind
        self.rawText = rawText
        self.digest = Block.sha256(rawText)
        self.ordinal = ordinal
        self.startLine = startLine
        self.occurrenceIndex = occurrenceIndex
    }

    /// Internal fast path: skips re-hashing `rawText` when the caller
    /// already knows the digest (e.g. reusing an untouched block from a
    /// prior parse under a new ordinal during incremental reparse).
    /// `occurrenceIndex` defaults to 0 since callers that splice blocks
    /// together must re-run `assigningOccurrenceIndices(to:)` over the
    /// final array anyway before trusting `id`.
    init(kind: BlockKind, rawText: String, digest: SIMD32<UInt8>, ordinal: Int, startLine: Int, occurrenceIndex: Int = 0) {
        self.kind = kind
        self.rawText = rawText
        self.digest = digest
        self.ordinal = ordinal
        self.startLine = startLine
        self.occurrenceIndex = occurrenceIndex
    }

    /// Stable identity used for diffing and list rendering.
    public var id: String { "\(contentHash)#\(occurrenceIndex)" }

    /// Returns `blocks` with `occurrenceIndex` assigned to reflect each
    /// block's position among others sharing the same `contentHash`, in
    /// document order (0 for the first occurrence of a given hash, 1 for
    /// the second, ...). This must be run over the FULL, final block
    /// array (or, for a streaming producer, threaded through the same
    /// running per-hash counters in document order) before `id` is
    /// trusted for diffing/`ForEach` identity. O(n) — one dictionary
    /// lookup/increment per block.
    static func assigningOccurrenceIndices(to blocks: [Block]) -> [Block] {
        var counts: [DigestKey: Int] = [:]
        counts.reserveCapacity(blocks.count)
        return blocks.map { block in
            let key = DigestKey(digest: block.digest)
            let index = counts[key, default: 0]
            counts[key] = index + 1
            return Block(
                kind: block.kind, rawText: block.rawText, digest: block.digest,
                ordinal: block.ordinal, startLine: block.startLine, occurrenceIndex: index
            )
        }
    }

    /// Fast identity comparison equivalent to `id == other.id` but without
    /// allocating/hex-encoding either side's `contentHash` string — used
    /// by `BlockDiffer`'s hot inner loops, which compare many blocks'
    /// identities but never need the string form itself.
    func hasSameIdentity(as other: Block) -> Bool {
        occurrenceIndex == other.occurrenceIndex && digest == other.digest
    }

    /// A `Hashable` wrapper around `digest` for use as a dictionary key.
    /// The synthesized `Hashable` conformance SIMD types get from the
    /// standard library combines all 32 lanes one at a time into the
    /// hasher, which measurably dominates parse/diff time at block counts
    /// in the tens of thousands (SHA-256 output is already uniformly
    /// distributed, so hashing all 32 bytes buys nothing over a single
    /// bulk combine). `Hasher.combine(bytes:)` hashes the same 32 bytes
    /// in one call instead of 32.
    struct DigestKey: Hashable {
        let digest: SIMD32<UInt8>
        static func == (a: DigestKey, b: DigestKey) -> Bool { a.digest == b.digest }
        func hash(into hasher: inout Hasher) {
            withUnsafeBytes(of: digest) { hasher.combine(bytes: $0) }
        }
    }

    static func sha256(_ text: String) -> SIMD32<UInt8> {
        var result = SIMD32<UInt8>()
        let digest = SHA256.hash(data: Data(text.utf8))
        var i = 0
        for byte in digest {
            result[i] = byte
            i += 1
        }
        return result
    }

    // `String(format: "%02x", byte)` per digest byte (the original
    // implementation) is a locale-aware printf call — 32 of those per
    // block turned out to be the single biggest cost in the whole parse
    // pipeline (~75% of total time on the 10 MB fixture, per
    // MarcoCoreBenchmark). A table-based hex encode is orders of
    // magnitude cheaper for the exact same output.
    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    private static func hex(_ digest: SIMD32<UInt8>) -> String {
        var hex = [UInt8]()
        hex.reserveCapacity(64)
        for i in 0..<32 {
            let byte = digest[i]
            hex.append(hexDigits[Int(byte >> 4)])
            hex.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: hex, as: UTF8.self)
    }
}
