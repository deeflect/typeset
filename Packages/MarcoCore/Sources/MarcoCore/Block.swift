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

    public init(kind: BlockKind, rawText: String, ordinal: Int) {
        self.kind = kind
        self.rawText = rawText
        self.contentHash = Block.hash(rawText)
        self.ordinal = ordinal
    }

    /// Stable identity used for diffing and list rendering.
    public var id: String { "\(contentHash)#\(ordinal)" }

    static func hash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
