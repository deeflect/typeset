import AppKit
import MarcoCore

// Debug-only: throwaway M6 Phase 0 spike (M6-PLAN.md §6). Answers one
// question — can a single TextKit 2 `NSTextView`, backed by the raw
// Markdown source, hit parity-or-better perf with the shipping
// `LazyVStack` reading view? Not shipping code: no styling polish, no
// error handling beyond keeping the harness running, never reachable
// outside a `MARCO_TEXTKIT_SPIKE_BENCH`-triggered run (see
// `TextKitSpikeBenchRunner`).
#if DEBUG

/// Custom attribute tagging a paragraph range as needing a painted
/// background (code block / blockquote) — read by `SpikeLayoutManagerDelegate`
/// to decide whether to hand back a `SpikeBackgroundLayoutFragment` for that
/// paragraph. Standing in for the "custom `NSTextLayoutFragment` subclass"
/// PLAN §1 proposes for code-block/blockquote chrome (Apple's
/// `BubbleLayoutFragment` sample pattern).
enum SpikeBlockBackgroundAttribute {
    static let key = NSAttributedString.Key("marco.spike.blockBackground")
}

/// Builds the TextKit 2 backing store: an `NSTextStorage` whose *characters*
/// are the raw Markdown source (unchanged), with styling applied purely as
/// attributes over ranges located via `Block.startLine` + `Block.rawText`.
/// Mirrors the real heading ramp in `MarcoRendering.Theme` so the attribute
/// cost (font-size/paragraph-style changes at heading boundaries) is
/// representative, and reuses the same bold/italic/inline-code regex
/// approach as `MarkdownSyntaxStyler` (the M3 source-editor styler) since
/// that is exactly "an attribute pass over raw source" — the M6 model.
///
/// Fidelity does not matter here (PLAN §0 spike scope) — only that the
/// attribute/fragment cost is representative of a real styling pass.
@MainActor
enum TextKit2SpikeStyler {
    /// Real heading sizes from `MarcoRendering.Theme.heading(level:)`,
    /// duplicated here (not imported — `Theme` lives in the SwiftUI-facing
    /// `MarcoRendering` module and returns `Font`, not `NSFont`) so the
    /// spike's attribute cost matches production's heading ramp.
    private static func headingFont(level: Int) -> NSFont {
        let size: CGFloat
        let weight: NSFont.Weight
        switch level {
        case 1: size = 30; weight = .bold
        case 2: size = 23; weight = .bold
        case 3: size = 18.5; weight = .semibold
        case 4: size = 15.5; weight = .semibold
        case 5: size = 13.5; weight = .semibold
        default: size = 12; weight = .semibold
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }

    private static func headingSpacing(level: Int) -> (before: CGFloat, after: CGFloat) {
        switch level {
        case 1: return (8, 12)
        case 2: return (30, 8)
        case 3: return (24, 6)
        case 4: return (20, 4)
        case 5: return (18, 3)
        default: return (16, 3)
        }
    }

    private static let bodyFont = NSFont.systemFont(ofSize: 15, weight: .regular)
    private static let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let codeBackground = NSColor.systemBlue.withAlphaComponent(0.08)
    private static let quoteBackground = NSColor.systemGray.withAlphaComponent(0.10)
    private static let dimColor = NSColor.tertiaryLabelColor
    private static let linkColor = NSColor.linkColor
    private static let codeTextColor = NSColor.systemBlue

    // Same shapes as `MarkdownSyntaxStyler`'s regexes — duplicated (not
    // imported) since those are `private` to that file; small enough that
    // reuse-by-copy is cheaper than plumbing a shared home for throwaway
    // spike code.
    private static let inlineCodePattern = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)
    private static let boldPattern = try! NSRegularExpression(pattern: #"(\*\*|__)([^\n]+?)\1"#)
    private static let italicPattern = try! NSRegularExpression(pattern: #"(?<![*_])([*_])([^\n*_]+?)\1(?![*_])"#)
    private static let linkPattern = try! NSRegularExpression(pattern: #"\[[^\]\n]*\]\([^)\n]*\)"#)
    private static let imagePattern = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(([^)\n]+)\)"#)

    /// `text` must be exactly the string `blocks` was parsed from (this
    /// spike's fixtures have no frontmatter, so `Block.startLine` maps
    /// directly onto lines of `text` with no offset correction needed).
    static func buildStorage(text: String, blocks: [Block]) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        let ns = text as NSString
        let lineStarts = lineStartOffsets(ns)
        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineSpacing = 6.5

        storage.beginEditing()
        let full = NSRange(location: 0, length: storage.length)
        storage.addAttribute(.font, value: bodyFont, range: full)
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: full)
        storage.addAttribute(.paragraphStyle, value: bodyParagraph, range: full)

        for block in blocks {
            guard block.startLine >= 0, block.startLine < lineStarts.count else { continue }
            let start = lineStarts[block.startLine]
            guard start < storage.length else { continue }
            let length = min(block.rawText.utf16.count, storage.length - start)
            guard length > 0 else { continue }
            let range = NSRange(location: start, length: length)
            apply(block.kind, range: range, storage: storage, text: ns)
        }
        storage.endEditing()
        return storage
    }

    private static func apply(_ kind: BlockKind, range: NSRange, storage: NSTextStorage, text: NSString) {
        switch kind {
        case .heading(let level):
            let (before, after) = headingSpacing(level: level)
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = before
            style.paragraphSpacing = after
            storage.addAttribute(.font, value: headingFont(level: level), range: range)
            storage.addAttribute(.paragraphStyle, value: style, range: range)

        case .codeBlock:
            storage.addAttribute(.font, value: codeFont, range: range)
            storage.addAttribute(SpikeBlockBackgroundAttribute.key, value: codeBackground, range: range)

        case .blockquote:
            let style = NSMutableParagraphStyle()
            style.headIndent = 16
            style.firstLineHeadIndent = 16
            storage.addAttribute(.paragraphStyle, value: style, range: range)
            storage.addAttribute(SpikeBlockBackgroundAttribute.key, value: quoteBackground, range: range)
            applyInline(range: range, storage: storage, text: text)

        case .frontmatter, .thematicBreak, .htmlBlock, .table:
            break

        case .paragraph, .list:
            applyInline(range: range, storage: storage, text: text)
        }
    }

    /// Bold/italic/inline-code/link regex sweep — the representative cost
    /// of an attribute-only inline styling pass over raw source (no
    /// character rewriting, matching PLAN §1's "concealment by attribute,
    /// not deletion" model).
    private static func applyInline(range: NSRange, storage: NSTextStorage, text: NSString) {
        let str = text as String
        inlineCodePattern.enumerateMatches(in: str, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.font, value: codeFont, range: match.range)
            storage.addAttribute(.foregroundColor, value: codeTextColor, range: match.range)
            storage.addAttribute(.backgroundColor, value: codeBackground, range: match.range)
        }
        boldPattern.enumerateMatches(in: str, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 15, weight: .bold), range: match.range(at: 2))
            dim(match: match, group: 1, storage: storage, text: text)
        }
        italicPattern.enumerateMatches(in: str, range: range) { match, _, _ in
            guard let match else { return }
            let italic = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
            storage.addAttribute(.font, value: italic, range: match.range(at: 2))
            dim(match: match, group: 1, storage: storage, text: text)
        }
        linkPattern.enumerateMatches(in: str, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.foregroundColor, value: linkColor, range: match.range)
        }
    }

    private static func dim(match: NSTextCheckingResult, group: Int, storage: NSTextStorage, text: NSString) {
        let delimiter = match.range(at: group)
        guard delimiter.location != NSNotFound else { return }
        let contentRange = match.range(at: group + 1)
        let closeRange = NSRange(location: contentRange.location + contentRange.length, length: delimiter.length)
        storage.addAttribute(.foregroundColor, value: dimColor, range: NSRange(location: match.range.location, length: delimiter.length))
        if closeRange.location + closeRange.length <= text.length {
            storage.addAttribute(.foregroundColor, value: dimColor, range: closeRange)
        }
    }

    // MARK: - Images (image-heavy fixture only)

    /// Finds `![alt](path)` spans and inserts an `NSTextAttachment`
    /// character right after each — PLAN §8 risk 4's "draw downsampled
    /// images" mitigation, applied here as a plain attachment (fidelity
    /// doesn't matter for the spike). Mutates `storage` in place; walks
    /// matches back-to-front so earlier offsets stay valid as later
    /// insertions shift the string. Resolves `path` relative to
    /// `baseDirectory`.
    static func insertImageAttachments(into storage: NSTextStorage, baseDirectory: URL) {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        let matches = imagePattern.matches(in: storage.string, range: full)
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3 else { continue }
            let pathRange = match.range(at: 2)
            let path = text.substring(with: pathRange)
            let url = baseDirectory.appendingPathComponent(path)
            guard let image = NSImage(contentsOf: url) else { continue }
            let attachment = NSTextAttachment()
            attachment.image = downsampled(image, maxDimension: 480)
            let attachmentString = NSAttributedString(attachment: attachment)
            storage.insert(attachmentString, at: match.range.location + match.range.length)
        }
    }

    /// Cheap downsample: draw into a smaller bitmap rather than shipping
    /// the full-resolution decoded image to the attachment cell (PLAN §8
    /// risk 4's stated mitigation for attachment cost on image-heavy docs).
    private static func downsampled(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(1, maxDimension / max(size.width, size.height))
        guard scale < 1 else { return image }
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)
        let small = NSImage(size: newSize)
        small.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize), from: .zero, operation: .copy, fraction: 1)
        small.unlockFocus()
        return small
    }

    // MARK: - Line offsets

    /// UTF-16 offset where each 0-based line starts, matching
    /// `Block.startLine`'s line counting. One O(n) pass via Foundation's
    /// line enumeration (same technique as `MarkdownSyntaxStyler.fenceLineSet`).
    private static func lineStartOffsets(_ text: NSString) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(text.length / 40)
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, _, enclosingRange, _ in
            offsets.append(enclosingRange.location)
        }
        return offsets
    }
}

// MARK: - Custom layout fragment (PLAN §1: code-block/blockquote chrome)

/// Paints a background fill behind its typographic bounds before deferring
/// to the default glyph drawing — the supported "Apple `BubbleLayoutFragment`
/// sample" pattern PLAN §1 cites for code-block/blockquote backgrounds.
final class SpikeBackgroundLayoutFragment: NSTextLayoutFragment {
    private let backgroundColor: NSColor

    init(textElement: NSTextElement, range: NSTextRange?, backgroundColor: NSColor) {
        self.backgroundColor = backgroundColor
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        let rect = CGRect(origin: point, size: layoutFragmentFrame.size).insetBy(dx: -6, dy: 0)
        context.setFillColor(backgroundColor.cgColor)
        context.fill(rect)
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}

/// Hands back `SpikeBackgroundLayoutFragment` for paragraphs tagged with
/// `SpikeBlockBackgroundAttribute` (code blocks / blockquotes), the default
/// fragment otherwise. Retained by the hosting view's coordinator for the
/// life of the text view (`NSTextLayoutManager.delegate` is weak).
final class SpikeLayoutManagerDelegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph,
            let color = paragraph.attributedString.attribute(SpikeBlockBackgroundAttribute.key, at: 0, effectiveRange: nil) as? NSColor
        {
            return SpikeBackgroundLayoutFragment(textElement: textElement, range: textElement.elementRange, backgroundColor: color)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}
#endif
