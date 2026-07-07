import AppKit
import MarcoCore
import MarcoRendering

/// Layout constants shared between the styler (paragraph indents) and the
/// layout fragment (bar / card geometry) so text and chrome stay aligned.
/// Deliberately unscaled — indentation reads fine without tracking the
/// text-size multiplier, and keeping it constant lets the fragment reason
/// about geometry without a `Theme` in hand.
enum MarcoReadingMetrics {
    static let quoteIndent: CGFloat = 18
    static let listIndent: CGFloat = 22
    static let listHang: CGFloat = 20
    static let codeTextInset: CGFloat = 12
    static let contentHorizontalPadding: CGFloat = 48
    static let contentMaxWidth: CGFloat = 720
    static let contentTopPadding: CGFloat = 40
}

/// Builds the TextKit 2 backing store for the M6 read-only reading surface:
/// an `NSTextStorage` whose *characters* are the raw Markdown source (syntax
/// markers stay visible — concealment is Phase 2), with the reading view's
/// visual decisions reproduced as attributes driven from the same `Theme`
/// tokens `MarcoRendering` uses. Block chrome (code cards, quote bars,
/// images) is tagged with custom attributes that `MarcoReadingLayoutFragment`
/// paints.
///
/// Fonts are rebuilt from the same numeric tokens as `Theme.heading(level:)` /
/// `Theme.bodySize` because `Theme` vends SwiftUI `Font` (not `NSFont`); colors
/// bridge directly from `Theme` via `NSColor(_:)`.
@MainActor
enum TextKitReadingStyler {

    struct Result {
        let storage: NSTextStorage
        let palette: ReadingDecorationPalette
    }

    // MARK: - Fonts (mirror Theme's ramp)

    private static func bodyFont(_ theme: Theme) -> NSFont {
        NSFont.systemFont(ofSize: 15 * theme.scale, weight: .regular)
    }
    private static func headingFont(level: Int, scale: CGFloat) -> NSFont {
        let (size, weight): (CGFloat, NSFont.Weight)
        switch level {
        case 1: (size, weight) = (30, .bold)
        case 2: (size, weight) = (23, .bold)
        case 3: (size, weight) = (18.5, .semibold)
        case 4: (size, weight) = (15.5, .semibold)
        case 5: (size, weight) = (13.5, .semibold)
        default: (size, weight) = (12, .semibold)
        }
        return NSFont.systemFont(ofSize: size * scale, weight: weight)
    }
    private static func headingSpacing(level: Int) -> (before: CGFloat, after: CGFloat, line: CGFloat) {
        switch level {
        case 1: return (8, 12, 2)
        case 2: return (30, 8, 1)
        case 3: return (24, 6, 0)
        case 4: return (20, 4, 0)
        case 5: return (18, 3, 0)
        default: return (16, 3, 0)
        }
    }
    private static func headingColor(level: Int, theme: Theme) -> NSColor {
        switch level {
        case 1...4: return NSColor(theme.textPrimary)
        case 5: return NSColor(theme.textSecondary)
        default: return NSColor(theme.textTertiary)
        }
    }
    private static func codeFont(_ theme: Theme) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: 13 * theme.scale, weight: .regular)
    }
    private static func inlineCodeFont(_ theme: Theme) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: 15 * 0.94 * theme.scale, weight: .regular)
    }

    // MARK: - Regex (same shapes as MarkdownSyntaxStyler)

    private static let inlineCodePattern = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)
    private static let boldPattern = try! NSRegularExpression(pattern: #"(\*\*|__)([^\n]+?)\1"#)
    private static let italicPattern = try! NSRegularExpression(pattern: #"(?<![*_])([*_])([^\n*_]+?)\1(?![*_])"#)
    private static let strikePattern = try! NSRegularExpression(pattern: #"(~~)([^\n]+?)~~"#)
    private static let linkPattern = try! NSRegularExpression(pattern: #"(?<!\!)\[([^\]\n]*)\]\(([^)\n]*)\)"#)
    private static let imagePattern = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(([^)\n]+)\)"#)

    // MARK: - Entry point

    static func build(text: String, blocks: [Block], theme: Theme, baseURL: URL?) -> Result {
        let palette = ReadingDecorationPalette(theme: theme)
        let storage = NSTextStorage(string: text)
        let ns = text as NSString
        guard ns.length > 0 else { return Result(storage: storage, palette: palette) }

        let lineStarts = lineStartOffsets(ns)
        let bodyOffset = MarkdownParser.bodyLineOffset(in: text)

        let base = bodyFont(theme)
        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineSpacing = 6.5 * theme.scale

        storage.beginEditing()
        let full = NSRange(location: 0, length: ns.length)
        storage.addAttribute(.font, value: base, range: full)
        storage.addAttribute(.foregroundColor, value: NSColor(theme.textPrimary), range: full)
        storage.addAttribute(.paragraphStyle, value: bodyParagraph, range: full)

        for block in blocks {
            let startLine = (block.kind == .frontmatter) ? 0 : block.startLine + bodyOffset
            guard startLine >= 0, startLine < lineStarts.count else { continue }
            let lineCount = max(1, block.rawText.isEmpty ? 1 : block.rawText.components(separatedBy: "\n").count)
            let endLine = startLine + lineCount
            let start = lineStarts[startLine]
            let end = endLine < lineStarts.count ? lineStarts[endLine] : ns.length
            guard start < end else { continue }
            let range = NSRange(location: start, length: end - start)
            apply(block.kind, blockRange: range, startLine: startLine, endLine: endLine,
                  lineStarts: lineStarts, storage: storage, ns: ns, theme: theme)
        }

        // Image pass over the whole document (images usually own their line).
        styleImages(storage: storage, ns: ns, theme: theme, baseURL: baseURL)

        storage.endEditing()
        return Result(storage: storage, palette: palette)
    }

    // MARK: - Per-block

    private static func apply(
        _ kind: BlockKind, blockRange: NSRange, startLine: Int, endLine: Int,
        lineStarts: [Int], storage: NSTextStorage, ns: NSString, theme: Theme
    ) {
        switch kind {
        case .heading(let level):
            let (before, after, line) = headingSpacing(level: level)
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = before * theme.scale
            style.paragraphSpacing = after * theme.scale
            style.lineSpacing = line * theme.scale
            storage.addAttribute(.font, value: headingFont(level: level, scale: theme.scale), range: blockRange)
            storage.addAttribute(.foregroundColor, value: headingColor(level: level, theme: theme), range: blockRange)
            storage.addAttribute(.paragraphStyle, value: style, range: blockRange)
            applyInline(range: blockRange, storage: storage, ns: ns, theme: theme, allowFontChange: false)

        case .paragraph:
            applyInline(range: blockRange, storage: storage, ns: ns, theme: theme, allowFontChange: true)

        case .list:
            eachLine(startLine: startLine, endLine: endLine, lineStarts: lineStarts, ns: ns) { lineRange in
                let level = listNestingLevel(ns.substring(with: lineRange))
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 6.5 * theme.scale
                style.firstLineHeadIndent = CGFloat(level) * MarcoReadingMetrics.listIndent
                style.headIndent = CGFloat(level) * MarcoReadingMetrics.listIndent + MarcoReadingMetrics.listHang
                storage.addAttribute(.paragraphStyle, value: style, range: lineRange)
            }
            applyInline(range: blockRange, storage: storage, ns: ns, theme: theme, allowFontChange: true)

        case .blockquote:
            let quoteColor = NSColor(theme.quoteText)
            eachLine(startLine: startLine, endLine: endLine, lineStarts: lineStarts, ns: ns) { lineRange in
                let depth = max(1, quoteDepth(ns.substring(with: lineRange)))
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 6.5 * theme.scale
                style.firstLineHeadIndent = CGFloat(depth) * MarcoReadingMetrics.quoteIndent + MarcoReadingMetrics.codeTextInset
                style.headIndent = style.firstLineHeadIndent
                storage.addAttribute(.paragraphStyle, value: style, range: lineRange)
                storage.addAttribute(.foregroundColor, value: quoteColor, range: lineRange)
                storage.addAttribute(.marcoQuoteDepth, value: NSNumber(value: depth), range: lineRange)
            }
            applyInline(range: blockRange, storage: storage, ns: ns, theme: theme, allowFontChange: true)

        case .codeBlock:
            let font = codeFont(theme)
            let codeText = NSColor(theme.textPrimary)
            var index = 0
            let count = endLine - startLine
            eachLine(startLine: startLine, endLine: endLine, lineStarts: lineStarts, ns: ns) { lineRange in
                var edge: CodeCardEdge = []
                if index == 0 { edge.insert(.top) }
                if index == count - 1 { edge.insert(.bottom) }
                index += 1
                let style = NSMutableParagraphStyle()
                style.firstLineHeadIndent = MarcoReadingMetrics.codeTextInset
                style.headIndent = MarcoReadingMetrics.codeTextInset
                storage.addAttribute(.paragraphStyle, value: style, range: lineRange)
                storage.addAttribute(.font, value: font, range: lineRange)
                storage.addAttribute(.foregroundColor, value: codeText, range: lineRange)
                storage.addAttribute(.marcoCodeCard, value: NSNumber(value: edge.rawValue), range: lineRange)
            }

        case .thematicBreak:
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.paragraphSpacingBefore = 10 * theme.scale
            style.paragraphSpacing = 10 * theme.scale
            storage.addAttribute(.paragraphStyle, value: style, range: blockRange)
            storage.addAttribute(.foregroundColor, value: NSColor(theme.textTertiary), range: blockRange)

        case .table:
            storage.addAttribute(.font, value: codeFont(theme), range: blockRange)
            storage.addAttribute(.foregroundColor, value: NSColor(theme.textSecondary), range: blockRange)

        case .frontmatter, .htmlBlock:
            storage.addAttribute(.font, value: codeFont(theme), range: blockRange)
            storage.addAttribute(.foregroundColor, value: NSColor(theme.textSecondary), range: blockRange)
        }
    }

    // MARK: - Inline

    private static func applyInline(
        range: NSRange, storage: NSTextStorage, ns: NSString, theme: Theme, allowFontChange: Bool
    ) {
        let str = ns as String

        inlineCodePattern.enumerateMatches(in: str, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.font, value: inlineCodeFont(theme), range: match.range)
            storage.addAttribute(.foregroundColor, value: NSColor(theme.inlineCodeText), range: match.range)
            storage.addAttribute(.backgroundColor, value: NSColor(theme.inlineCodeFill), range: match.range)
            // Click-to-copy + pointing-hand pointer, same contract as the
            // shipping reading view (`InlineCodeCopy`). Carried on a custom
            // attribute (not `.link`) so the chip never picks up link tint /
            // underline. The inner span (minus backticks) is the copied text.
            let inner = NSRange(location: match.range.location + 1, length: max(0, match.range.length - 2))
            if inner.length > 0 {
                storage.addAttribute(.marcoCopyText, value: ns.substring(with: inner) as NSString, range: match.range)
            }
        }

        if allowFontChange {
            boldPattern.enumerateMatches(in: str, range: range) { match, _, _ in
                guard let match, let base = storage.attribute(.font, at: match.range(at: 2).location, effectiveRange: nil) as? NSFont else { return }
                let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
                storage.addAttribute(.font, value: bold, range: match.range(at: 2))
            }
            italicPattern.enumerateMatches(in: str, range: range) { match, _, _ in
                guard let match, let base = storage.attribute(.font, at: match.range(at: 2).location, effectiveRange: nil) as? NSFont else { return }
                let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
                storage.addAttribute(.font, value: italic, range: match.range(at: 2))
            }
            strikePattern.enumerateMatches(in: str, range: range) { match, _, _ in
                guard let match else { return }
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: match.range(at: 2))
            }
        }

        linkPattern.enumerateMatches(in: str, range: range) { match, _, _ in
            guard let match, match.numberOfRanges >= 3 else { return }
            let target = ns.substring(with: match.range(at: 2))
            storage.addAttribute(.foregroundColor, value: NSColor(theme.linkColor), range: match.range)
            if let url = linkURL(target) {
                storage.addAttribute(.link, value: url, range: match.range)
            }
        }
    }

    private static func styleImages(storage: NSTextStorage, ns: NSString, theme: Theme, baseURL: URL?) {
        let full = NSRange(location: 0, length: ns.length)
        imagePattern.enumerateMatches(in: ns as String, range: full) { match, _, _ in
            guard let match, match.numberOfRanges >= 3 else { return }
            let alt = ns.substring(with: match.range(at: 1))
            let path = ns.substring(with: match.range(at: 2))
            guard let url = imageURL(path, baseURL: baseURL) else { return }
            guard let pixel = ReadingImageStore.pixelSize(of: url) else { return }
            let usable = MarcoReadingMetrics.contentMaxWidth - MarcoReadingMetrics.contentHorizontalPadding * 2
            let width = min(pixel.width, usable)
            let height = pixel.height * (width / max(pixel.width, 1))
            let decoration = MarcoImageDecoration(url: url, alt: alt, displaySize: CGSize(width: width, height: height))
            // Tag the whole line so the attribute is present at the paragraph's
            // index 0 (where the fragment reads it).
            let lineRange = ns.lineRange(for: NSRange(location: match.range.location, length: 0))
            storage.addAttribute(.marcoImage, value: decoration, range: lineRange)
            // Dim the alt-text link markup so the drawn image is the focus.
            storage.addAttribute(.foregroundColor, value: NSColor(theme.textTertiary), range: match.range)
        }
    }

    // MARK: - Helpers

    private static func linkURL(_ raw: String) -> URL? {
        if let url = URL(string: raw) { return url }
        if let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            return URL(string: encoded)
        }
        return nil
    }

    private static func imageURL(_ path: String, baseURL: URL?) -> URL? {
        if let url = URL(string: path), url.scheme != nil { return url }
        guard let baseURL else { return nil }
        return baseURL.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
    }

    /// Nesting level from leading whitespace (two spaces / one tab per level).
    private static func listNestingLevel(_ line: String) -> Int {
        var spaces = 0
        for ch in line {
            if ch == " " { spaces += 1 }
            else if ch == "\t" { spaces += 2 }
            else { break }
        }
        return spaces / 2
    }

    /// Blockquote nesting depth from leading `>` markers (`> > x` → 2).
    private static func quoteDepth(_ line: String) -> Int {
        var depth = 0
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == ">" { depth += 1 }
            else if ch == " " || ch == "\t" { /* skip */ }
            else { break }
            i = line.index(after: i)
        }
        return depth
    }

    private static func eachLine(
        startLine: Int, endLine: Int, lineStarts: [Int], ns: NSString, _ body: (NSRange) -> Void
    ) {
        for line in startLine..<endLine {
            guard line < lineStarts.count else { break }
            let s = lineStarts[line]
            let e = (line + 1) < lineStarts.count ? lineStarts[line + 1] : ns.length
            guard s < e else { continue }
            body(NSRange(location: s, length: e - s))
        }
    }

    private static func lineStartOffsets(_ text: NSString) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(text.length / 40 + 1)
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, _, enclosingRange, _ in
            offsets.append(enclosingRange.location)
        }
        if offsets.isEmpty { offsets.append(0) }
        return offsets
    }
}
