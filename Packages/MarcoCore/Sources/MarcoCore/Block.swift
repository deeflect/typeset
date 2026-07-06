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
    /// SHA-256 hex digest of `rawText`.
    public let contentHash: String
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

    public init(kind: BlockKind, rawText: String, ordinal: Int, startLine: Int = -1) {
        self.kind = kind
        self.rawText = rawText
        self.contentHash = Block.hash(rawText)
        self.ordinal = ordinal
        self.startLine = startLine
    }

    /// Internal fast path: skips re-hashing `rawText` when the caller
    /// already knows the hash (e.g. reusing an untouched block from a
    /// prior parse under a new ordinal during incremental reparse).
    init(kind: BlockKind, rawText: String, contentHash: String, ordinal: Int, startLine: Int) {
        self.kind = kind
        self.rawText = rawText
        self.contentHash = contentHash
        self.ordinal = ordinal
        self.startLine = startLine
    }

    /// Stable identity used for diffing and list rendering.
    public var id: String { "\(contentHash)#\(ordinal)" }

    // `String(format: "%02x", byte)` per digest byte (the original
    // implementation) is a locale-aware printf call — 32 of those per
    // block turned out to be the single biggest cost in the whole parse
    // pipeline (~75% of total time on the 10 MB fixture, per
    // MarcoCoreBenchmark). A table-based hex encode is orders of
    // magnitude cheaper for the exact same output.
    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    static func hash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        var hex = [UInt8]()
        hex.reserveCapacity(64)
        for byte in digest {
            hex.append(hexDigits[Int(byte >> 4)])
            hex.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: hex, as: UTF8.self)
    }
}
