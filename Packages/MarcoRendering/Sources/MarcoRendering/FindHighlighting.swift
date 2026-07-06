import SwiftUI

/// Identifies one searchable/highlightable text run in the rendered
/// document. Top-level heading/paragraph/code blocks use `childID == nil`;
/// text nested inside a list item or blockquote uses the owning top-level
/// block's id plus the `StructuredChild.id` of the leaf, which is stable for
/// a given block because `BlockStructureCache` hands out the same parsed
/// model (and thus the same generated child ids) to both the segment builder
/// and the views that render it.
public struct FindSegmentKey: Hashable, Sendable {
    public let blockID: String
    public let childID: Int?

    public init(blockID: String, childID: Int?) {
        self.blockID = blockID
        self.childID = childID
    }
}

/// The read-only slice of find state a block view needs to tint its matches.
/// `nil` in the environment (the default) means find is closed → block views
/// do zero find work, so scrolling with the bar shut costs nothing.
public struct FindHighlightContext: Equatable {
    public var query: String
    public var caseSensitive: Bool
    public var currentKey: FindSegmentKey?
    /// `Character` offset of the current match within its segment text — only
    /// meaningful for the segment whose key equals `currentKey`.
    public var currentStart: Int?

    public init(query: String, caseSensitive: Bool, currentKey: FindSegmentKey?, currentStart: Int?) {
        self.query = query
        self.caseSensitive = caseSensitive
        self.currentKey = currentKey
        self.currentStart = currentStart
    }
}

public extension EnvironmentValues {
    /// Active find highlight, injected by the reading view when the ⌘F bar is
    /// open. `nil` ⇒ no highlighting work at all.
    @Entry var findHighlight: FindHighlightContext? = nil
    /// The top-level `Block.id` a leaf text view belongs to, so it can form
    /// its `FindSegmentKey`. Set once by `BlockView`; inherited through nested
    /// list/quote content.
    @Entry var findBlockID: String? = nil
}

/// Applies ⌘F match tints onto a block's rendered `AttributedString`. Scans
/// the string's own characters for the query (so highlight ranges are always
/// valid for the exact text on screen) and paints every occurrence; the one
/// starting at `currentStart` — passed only for the current segment — gets
/// the stronger "current match" treatment.
public enum FindHighlighting {
    public static func apply(
        to attr: inout AttributedString, query: String, caseSensitive: Bool,
        currentStart: Int?, theme: Theme
    ) {
        guard !query.isEmpty else { return }
        let plain = String(attr.characters)
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var searchStart = plain.startIndex
        while let range = plain.range(of: query, options: options, range: searchStart..<plain.endIndex) {
            let startOffset = plain.distance(from: plain.startIndex, to: range.lowerBound)
            let length = plain.distance(from: range.lowerBound, to: range.upperBound)
            let lower = attr.index(attr.startIndex, offsetByCharacters: startOffset)
            let upper = attr.index(lower, offsetByCharacters: length)
            let isCurrent = currentStart == startOffset
            attr[lower..<upper].backgroundColor = isCurrent ? theme.findCurrentHighlight : theme.findMatchHighlight
            if isCurrent {
                attr[lower..<upper].foregroundColor = theme.findCurrentText
            }
            searchStart = range.upperBound == range.lowerBound
                ? plain.index(after: range.lowerBound)
                : range.upperBound
            if searchStart >= plain.endIndex { break }
        }
    }
}

/// Convenience used by every leaf text view (`HeadingView`, `ParagraphView`,
/// `CodeBlockView`) to tint its ⌘F matches. Returns `base` untouched — and
/// does no work — when find is closed or this view has no block identity.
@MainActor
func applyingFindHighlight(
    _ base: AttributedString, context: FindHighlightContext?,
    blockID: String?, childID: Int?, theme: Theme
) -> AttributedString {
    guard let context, let blockID else { return base }
    var copy = base
    let key = FindSegmentKey(blockID: blockID, childID: childID)
    let currentStart = context.currentKey == key ? context.currentStart : nil
    FindHighlighting.apply(
        to: &copy, query: context.query, caseSensitive: context.caseSensitive,
        currentStart: currentStart, theme: theme)
    return copy
}
