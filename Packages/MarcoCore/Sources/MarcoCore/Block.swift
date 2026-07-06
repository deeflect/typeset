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
/// `ordinal`, a 0-based counter that disambiguates otherwise-identical
/// blocks (e.g. two blank `---` thematic breaks in a row) so each block
/// still has a stable, unique `id` for diffing and SwiftUI `ForEach`.
public struct Block: Identifiable, Equatable, Sendable {
    public let kind: BlockKind
    /// Raw Markdown source text for this block (used for hashing and,
    /// for now, as the plumbing-proof render payload).
    public let rawText: String
    /// Disambiguates duplicate `contentHash` values within a document.
    public let ordinal: Int
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

    public init(kind: BlockKind, rawText: String, ordinal: Int, startLine: Int = -1) {
        self.kind = kind
        self.rawText = rawText
        self.digest = Block.sha256(rawText)
        self.ordinal = ordinal
        self.startLine = startLine
    }

    /// Internal fast path: skips re-hashing `rawText` when the caller
    /// already knows the digest (e.g. reusing an untouched block from a
    /// prior parse under a new ordinal during incremental reparse).
    init(kind: BlockKind, rawText: String, digest: SIMD32<UInt8>, ordinal: Int, startLine: Int) {
        self.kind = kind
        self.rawText = rawText
        self.digest = digest
        self.ordinal = ordinal
        self.startLine = startLine
    }

    /// Stable identity used for diffing and list rendering.
    public var id: String { "\(contentHash)#\(ordinal)" }

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
