import MarcoCore
import Observation
import SwiftUI

/// Identifies one searchable/highlightable text run in the rendered
/// document. Top-level heading/paragraph/code blocks use `childID == nil`;
/// text nested inside a list item or blockquote uses the owning top-level
/// block's id plus the `StructuredChild.id` of the leaf, which is stable for
/// a given block because `BlockStructureCache` hands out the same parsed
/// model (and thus the same generated child ids) to both the segment builder
/// here and the views that render it.
struct FindSegmentKey: Hashable, Sendable {
    let blockID: String
    let childID: Int?
}

/// The read-only slice of find state a block view needs to tint its matches.
/// `nil` in the environment (the default) means find is closed → block views
/// do zero find work, so scrolling with the bar shut costs nothing.
struct FindHighlightContext: Equatable {
    var query: String
    var caseSensitive: Bool
    var currentKey: FindSegmentKey?
    /// `Character` offset of the current match within its segment text — only
    /// meaningful for the segment whose key equals `currentKey`.
    var currentStart: Int?
}

extension EnvironmentValues {
    /// Active find highlight, injected by the reading view when the ⌘F bar is
    /// open. `nil` ⇒ no highlighting work at all.
    @Entry var findHighlight: FindHighlightContext? = nil
    /// The top-level `Block.id` a leaf text view belongs to, so it can form
    /// its `FindSegmentKey`. Set once by `BlockView`; inherited through nested
    /// list/quote content.
    @Entry var findBlockID: String? = nil
}

/// Per-window ⌘F state: the query, the searchable segment texts (kept in
/// lockstep with what the block views render, so match counts equal what's
/// tinted), the ordered matches from `FindEngine`, and the current index that
/// ⌘G / ⌘⇧G step through.
@Observable
@MainActor
final class FindSession {
    var isActive = false
    var query = ""
    var caseSensitive = false {
        didSet { guard caseSensitive != oldValue else { return }; recomputeMatches() }
    }

    /// Parallel arrays: `keys[i]` identifies the run whose text is `texts[i]`.
    private(set) var keys: [FindSegmentKey] = []
    private(set) var texts: [String] = []
    private(set) var matches: [FindMatch] = []
    private(set) var currentIndex = 0

    var matchCount: Int { matches.count }

    /// "3 of 17" — the count chip in the find bar. Empty when there's no
    /// query; a distinct "no results" when the query finds nothing.
    var statusText: String {
        if query.isEmpty { return "" }
        if matches.isEmpty { return "No results" }
        return "\(currentIndex + 1) of \(matches.count)"
    }

    var currentMatch: FindMatch? {
        matches.indices.contains(currentIndex) ? matches[currentIndex] : nil
    }
    var currentKey: FindSegmentKey? { currentMatch.map { keys[$0.segmentIndex] } }
    /// The top-level block id to scroll the current match into view.
    var currentBlockID: String? { currentKey?.blockID }

    /// The environment payload block views read to tint matches; `nil` when
    /// closed or empty so views short-circuit.
    var highlightContext: FindHighlightContext? {
        guard isActive, !query.isEmpty else { return nil }
        return FindHighlightContext(
            query: query, caseSensitive: caseSensitive,
            currentKey: currentKey, currentStart: currentMatch?.start)
    }

    // MARK: - Lifecycle

    func open(blocks: [Block]) {
        isActive = true
        rebuildSegments(from: blocks)
    }

    func close() {
        isActive = false
        query = ""
        matches = []
        keys = []
        texts = []
        currentIndex = 0
    }

    /// Bumped each time a segment rebuild starts so a slower earlier build
    /// (e.g. from a prior reload) can't clobber a newer one when it lands.
    private var buildGeneration = 0

    /// Rebuilds the searchable segments — on open and on every live reload
    /// while the bar is open — off the main actor, then re-runs the query on
    /// the main actor. Building is O(blocks) with a per-block inline parse
    /// (~700 ms on a 1 MB / 24k-block file), so it must never block the main
    /// thread: match tints appear instantly from the query alone; the count
    /// and current-match navigation catch up when the build lands. The
    /// `FindSegmentBuilder` is fully `nonisolated`, so this is safe off-main.
    func rebuildSegments(from blocks: [Block]) {
        buildGeneration += 1
        let generation = buildGeneration
        Task.detached(priority: .userInitiated) {
            let result = FindSegmentBuilder.build(from: blocks)
            await MainActor.run { [weak self] in
                guard let self, self.buildGeneration == generation else { return }
                self.keys = result.keys
                self.texts = result.texts
                self.recomputeMatches()
            }
        }
    }

    func setQuery(_ newValue: String) {
        query = newValue
        currentIndex = 0
        recomputeMatches()
    }

    func next() {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex + 1) % matches.count
    }

    func previous() {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex - 1 + matches.count) % matches.count
    }

    private func recomputeMatches() {
        matches = query.isEmpty ? [] : FindEngine.search(query: query, in: texts, caseSensitive: caseSensitive)
        if matches.isEmpty {
            currentIndex = 0
        } else {
            currentIndex = min(max(currentIndex, 0), matches.count - 1)
        }
    }
}

/// Applies ⌘F match tints onto a block's rendered `AttributedString`. Scans
/// the string's own characters for the query (so highlight ranges are always
/// valid for the exact text on screen) and paints every occurrence; the one
/// starting at `currentStart` — passed only for the current segment — gets
/// the stronger "current match" treatment.
enum FindHighlighting {
    static func apply(
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

/// Builds the ordered searchable segments from the block model. Each segment
/// text is the *plain rendered* text of a leaf run (via
/// `InlineMarkdown.plainText`, character-identical to what `Text` shows), so
/// `FindEngine` match counts equal the tinted occurrences. Covered: headings,
/// paragraphs, code blocks, and the same three kinds nested inside list items
/// and blockquotes. Excluded (documented v1 gap): table cells, frontmatter,
/// raw HTML blocks, and image-only paragraphs (no text to tint).
enum FindSegmentBuilder {
    static func build(from blocks: [Block]) -> (keys: [FindSegmentKey], texts: [String]) {
        var keys: [FindSegmentKey] = []
        var texts: [String] = []
        for block in blocks {
            switch block.kind {
            case .heading:
                let text = InlineMarkdown.plainText(BlockStructureCache.shared.headingText(for: block))
                append(&keys, &texts, key: .init(blockID: block.id, childID: nil), text: text)
            case .paragraph:
                guard InlineImage.soleImage(in: block.rawText) == nil else { continue }
                append(&keys, &texts, key: .init(blockID: block.id, childID: nil), text: InlineMarkdown.plainText(block.rawText))
            case .codeBlock:
                append(&keys, &texts, key: .init(blockID: block.id, childID: nil), text: CodeBlockView.extractCode(block.rawText))
            case .list:
                if let model = BlockStructureCache.shared.list(for: block) {
                    collectList(model, blockID: block.id, keys: &keys, texts: &texts)
                }
            case .blockquote:
                if let model = BlockStructureCache.shared.quote(for: block) {
                    collectChildren(model.children, blockID: block.id, keys: &keys, texts: &texts)
                }
            case .frontmatter, .table, .thematicBreak, .htmlBlock:
                continue
            }
        }
        return (keys, texts)
    }

    private static func collectList(_ model: ListModel, blockID: String, keys: inout [FindSegmentKey], texts: inout [String]) {
        for item in model.items {
            collectChildren(item.children, blockID: blockID, keys: &keys, texts: &texts)
        }
    }

    private static func collectChildren(_ children: [StructuredChild], blockID: String, keys: inout [FindSegmentKey], texts: inout [String]) {
        for child in children {
            switch child.kind {
            case .paragraph(let text):
                guard InlineImage.soleImage(in: text) == nil else { continue }
                append(&keys, &texts, key: .init(blockID: blockID, childID: child.id), text: InlineMarkdown.plainText(text))
            case .heading(_, let text):
                append(&keys, &texts, key: .init(blockID: blockID, childID: child.id), text: InlineMarkdown.plainText(text))
            case .codeBlock(_, let raw):
                append(&keys, &texts, key: .init(blockID: blockID, childID: child.id), text: CodeBlockView.extractCode(raw))
            case .list(let nested):
                collectList(nested, blockID: blockID, keys: &keys, texts: &texts)
            case .quote(let nested):
                collectChildren(nested.children, blockID: blockID, keys: &keys, texts: &texts)
            case .table, .thematicBreak, .htmlBlock:
                continue
            }
        }
    }

    private static func append(_ keys: inout [FindSegmentKey], _ texts: inout [String], key: FindSegmentKey, text: String) {
        keys.append(key)
        texts.append(text)
    }
}
