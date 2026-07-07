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
/// an `NSTextStorage` whose *characters* are the raw Markdown source, styled
/// from the same `Theme` tokens `MarcoRendering` uses. Syntax markers (Phase 2)
/// are concealed by zero-advance attributes (a near-zero-point clear font), so
/// display length == store length and caret/selection/copy stay native and
/// yield source. Block chrome (code cards, quote bars, images, thematic rules,
/// list bullets, inline-code chips) is tagged with custom attributes that
/// `MarcoReadingLayoutFragment` paints.
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

    // MARK: - Regex

    // Inline (same shapes as MarkdownSyntaxStyler).
    private static let inlineCodePattern = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)
    private static let boldPattern = try! NSRegularExpression(pattern: #"(\*\*|__)([^\n]+?)\1"#)
    private static let italicPattern = try! NSRegularExpression(pattern: #"(?<![*_])([*_])([^\n*_]+?)\1(?![*_])"#)
    private static let strikePattern = try! NSRegularExpression(pattern: #"(~~)([^\n]+?)~~"#)
    private static let linkPattern = try! NSRegularExpression(pattern: #"(?<!\!)\[([^\]\n]*)\]\(([^)\n]*)\)"#)
    private static let imagePattern = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(([^)\n]+)\)"#)
    // Line-prefix markers to conceal.
    private static let headingPrefixPattern = try! NSRegularExpression(pattern: #"^#{1,6}[ \t]+"#)
    private static let quotePrefixPattern = try! NSRegularExpression(pattern: #"^[ \t]*(?:>[ \t]?)+"#)
    private static let ulMarkerPattern = try! NSRegularExpression(pattern: #"^[ \t]*[-*+][ \t]+"#)
    private static let olIndentPattern = try! NSRegularExpression(pattern: #"^[ \t]+(?=\d+[.)][ \t])"#)
    private static let fencePattern = try! NSRegularExpression(pattern: #"^[ \t]*(```|~~~)"#)
    private static let thematicPattern = try! NSRegularExpression(pattern: #"^[ \t]*([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)

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

        // Fenced code blocks, at any nesting depth, found by scanning source
        // lines for fence pairs — independent of block nesting, which is what
        // fixes the "nested code block gets no card" bug (a code block inside a
        // list is a `.list` top-level block, invisible to the per-BlockKind
        // walk below). Recorded so the block walk can skip styling code lines.
        let codeLineSet = fencedCodeLines(lineStarts: lineStarts, ns: ns)

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
                  lineStarts: lineStarts, codeLineSet: codeLineSet,
                  storage: storage, ns: ns, theme: theme)
        }

        // Authoritative code-block pass: applies the card + mono + fence
        // concealment to every fenced range and *clears* any inline styling the
        // block walk applied when it mistook a nested code block for prose.
        styleFencedCode(codeLineSet: codeLineSet, lineStarts: lineStarts, storage: storage, ns: ns, theme: theme)

        // Image pass over the whole document (images usually own their line).
        styleImages(storage: storage, ns: ns, theme: theme, baseURL: baseURL)

        storage.endEditing()
        return Result(storage: storage, palette: palette)
    }

    // MARK: - Per-block

    private static func apply(
        _ kind: BlockKind, blockRange: NSRange, startLine: Int, endLine: Int,
        lineStarts: [Int], codeLineSet: Set<Int>, storage: NSTextStorage, ns: NSString, theme: Theme
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
            concealFirstMatch(headingPrefixPattern, inLine: startLine, lineStarts: lineStarts, storage: storage, ns: ns)
            applyInline(range: blockRange, storage: storage, ns: ns, theme: theme, allowFontChange: false)

        case .paragraph:
            if thematicMatch(startLine: startLine, endLine: endLine, lineStarts: lineStarts, ns: ns) {
                styleThematicBreak(startLine: startLine, lineStarts: lineStarts, storage: storage, ns: ns, theme: theme)
                return
            }
            applyInline(range: blockRange, storage: storage, ns: ns, theme: theme, allowFontChange: true)

        case .list:
            eachLine(startLine: startLine, endLine: endLine, lineStarts: lineStarts, ns: ns) { lineRange, lineIndex in
                if codeLineSet.contains(lineIndex) { return }  // code handled separately
                let text = ns.substring(with: lineRange)
                styleListLine(lineRange: lineRange, text: text, storage: storage, theme: theme)
            }
            applyInline(range: blockRange, storage: storage, ns: ns, theme: theme, allowFontChange: true,
                        skipCodeLines: codeLineSet, lineStarts: lineStarts)

        case .blockquote:
            let quoteColor = NSColor(theme.quoteText)
            eachLine(startLine: startLine, endLine: endLine, lineStarts: lineStarts, ns: ns) { lineRange, lineIndex in
                if codeLineSet.contains(lineIndex) { return }
                let depth = max(1, quoteDepth(ns.substring(with: lineRange)))
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 6.5 * theme.scale
                style.firstLineHeadIndent = CGFloat(depth) * MarcoReadingMetrics.quoteIndent + MarcoReadingMetrics.codeTextInset
                style.headIndent = style.firstLineHeadIndent
                storage.addAttribute(.paragraphStyle, value: style, range: lineRange)
                storage.addAttribute(.foregroundColor, value: quoteColor, range: lineRange)
                storage.addAttribute(.marcoQuoteDepth, value: NSNumber(value: depth), range: lineRange)
                concealFirstMatch(quotePrefixPattern, inLineRange: lineRange, storage: storage, ns: ns)
            }
            applyInline(range: blockRange, storage: storage, ns: ns, theme: theme, allowFontChange: true,
                        skipCodeLines: codeLineSet, lineStarts: lineStarts)

        case .codeBlock:
            // Fenced code blocks are handled by `styleFencedCode`. An *indented*
            // (non-fenced) top-level code block has no fence lines, so style it
            // here as a plain mono card.
            if !codeLineSet.contains(startLine) {
                applyCodeCard(startLine: startLine, endLine: endLine, fenceLines: [],
                              lineStarts: lineStarts, storage: storage, ns: ns, theme: theme)
            }

        case .thematicBreak:
            styleThematicBreak(startLine: startLine, lineStarts: lineStarts, storage: storage, ns: ns, theme: theme)

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
        range: NSRange, storage: NSTextStorage, ns: NSString, theme: Theme, allowFontChange: Bool,
        skipCodeLines: Set<Int> = [], lineStarts: [Int] = []
    ) {
        let str = ns as String

        func inCode(_ r: NSRange) -> Bool {
            guard !skipCodeLines.isEmpty else { return false }
            let line = lineIndex(ofOffset: r.location, lineStarts: lineStarts)
            return skipCodeLines.contains(line)
        }

        inlineCodePattern.enumerateMatches(in: str, range: range) { match, _, _ in
            guard let match, !inCode(match.range) else { return }
            let inner = NSRange(location: match.range.location + 1, length: max(0, match.range.length - 2))
            // Conceal the two backticks; keep the inner code text as a chip.
            conceal(storage, NSRange(location: match.range.location, length: 1))
            conceal(storage, NSRange(location: match.range.location + match.range.length - 1, length: 1))
            guard inner.length > 0 else { return }
            storage.addAttribute(.font, value: inlineCodeFont(theme), range: inner)
            storage.addAttribute(.foregroundColor, value: NSColor(theme.inlineCodeText), range: inner)
            // Rounded chip drawn by the layout fragment (not a flat background
            // attribute) — one padded strip per line, no ragged mid-word edges.
            storage.addAttribute(.marcoInlineChip, value: NSNumber(value: true), range: inner)
            // Click-to-copy pointer/contract (same as the shipping reading view).
            storage.addAttribute(.marcoCopyText, value: ns.substring(with: inner) as NSString, range: inner)
        }

        if allowFontChange {
            boldPattern.enumerateMatches(in: str, range: range) { match, _, _ in
                guard let match, !inCode(match.range),
                      let baseFont = storage.attribute(.font, at: match.range(at: 2).location, effectiveRange: nil) as? NSFont else { return }
                let bold = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
                storage.addAttribute(.font, value: bold, range: match.range(at: 2))
                concealDelimiters(around: match, delimLength: match.range(at: 1).length, storage: storage)
            }
            italicPattern.enumerateMatches(in: str, range: range) { match, _, _ in
                guard let match, !inCode(match.range),
                      let baseFont = storage.attribute(.font, at: match.range(at: 2).location, effectiveRange: nil) as? NSFont else { return }
                let italic = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                storage.addAttribute(.font, value: italic, range: match.range(at: 2))
                concealDelimiters(around: match, delimLength: 1, storage: storage)
            }
            strikePattern.enumerateMatches(in: str, range: range) { match, _, _ in
                guard let match, !inCode(match.range) else { return }
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: match.range(at: 2))
                concealDelimiters(around: match, delimLength: 2, storage: storage)
            }
        }

        linkPattern.enumerateMatches(in: str, range: range) { match, _, _ in
            guard let match, match.numberOfRanges >= 3, !inCode(match.range) else { return }
            let textRange = match.range(at: 1)
            let target = ns.substring(with: match.range(at: 2))
            storage.addAttribute(.foregroundColor, value: NSColor(theme.linkColor), range: textRange)
            if let url = linkURL(target) {
                storage.addAttribute(.link, value: url, range: textRange)
            }
            // Conceal the `[` before the text and the `](url)` after it.
            conceal(storage, NSRange(location: match.range.location, length: 1))
            let tailStart = textRange.location + textRange.length
            conceal(storage, NSRange(location: tailStart, length: match.range.location + match.range.length - tailStart))
        }
    }

    // MARK: - Code blocks

    /// Line indices (in `lineStarts` space) that are inside a fenced code block
    /// (fences included), found by a source-line scan so nested fenced blocks
    /// are covered regardless of their container's block kind.
    private static func fencedCodeLines(lineStarts: [Int], ns: NSString) -> Set<Int> {
        var lines = Set<Int>()
        var open = false
        for i in lineStarts.indices {
            let s = lineStarts[i]
            let e = (i + 1) < lineStarts.count ? lineStarts[i + 1] : ns.length
            let line = ns.substring(with: NSRange(location: s, length: e - s))
            let isFence = fencePattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
            if isFence {
                lines.insert(i)
                open.toggle()
            } else if open {
                lines.insert(i)
            }
        }
        return lines
    }

    private static func styleFencedCode(
        codeLineSet: Set<Int>, lineStarts: [Int], storage: NSTextStorage, ns: NSString, theme: Theme
    ) {
        guard !codeLineSet.isEmpty else { return }
        // Group consecutive code lines into contiguous blocks.
        let sorted = codeLineSet.sorted()
        var runStart = sorted[0]
        var prev = sorted[0]
        func flush(_ endInclusive: Int) {
            var fences: [Int] = []
            let firstLine = ns.substring(with: lineRange(runStart, lineStarts: lineStarts, ns: ns))
            if isFence(firstLine) { fences.append(runStart) }
            let lastLine = ns.substring(with: lineRange(endInclusive, lineStarts: lineStarts, ns: ns))
            if endInclusive != runStart, isFence(lastLine) { fences.append(endInclusive) }
            applyCodeCard(startLine: runStart, endLine: endInclusive + 1, fenceLines: fences,
                          lineStarts: lineStarts, storage: storage, ns: ns, theme: theme)
        }
        for line in sorted.dropFirst() {
            if line == prev + 1 { prev = line; continue }
            flush(prev)
            runStart = line
            prev = line
        }
        flush(prev)
    }

    private static func applyCodeCard(
        startLine: Int, endLine: Int, fenceLines: [Int],
        lineStarts: [Int], storage: NSTextStorage, ns: NSString, theme: Theme
    ) {
        let font = codeFont(theme)
        let codeText = NSColor(theme.textPrimary)
        let count = endLine - startLine
        var index = 0
        eachLine(startLine: startLine, endLine: endLine, lineStarts: lineStarts, ns: ns) { lineRange, lineIndex in
            var edge: CodeCardEdge = []
            if index == 0 { edge.insert(.top) }
            if index == count - 1 { edge.insert(.bottom) }
            index += 1
            // Clear anything the prose walk applied when it mistook a nested
            // code block for prose (inline chip fills, copy targets, links).
            // The font/color reset below also un-conceals any emphasis markers
            // the prose walk hid inside the code.
            storage.removeAttribute(.marcoInlineChip, range: lineRange)
            storage.removeAttribute(.marcoCopyText, range: lineRange)
            storage.removeAttribute(.backgroundColor, range: lineRange)
            storage.removeAttribute(.link, range: lineRange)
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = MarcoReadingMetrics.codeTextInset
            style.headIndent = MarcoReadingMetrics.codeTextInset
            storage.addAttribute(.paragraphStyle, value: style, range: lineRange)
            storage.addAttribute(.font, value: font, range: lineRange)
            storage.addAttribute(.foregroundColor, value: codeText, range: lineRange)
            storage.addAttribute(.marcoCodeCard, value: NSNumber(value: edge.rawValue), range: lineRange)
            // Hide the fence line's text but keep its height as card padding
            // (invisible, metrics-preserving).
            if fenceLines.contains(lineIndex) {
                let contentLen = trailingNewlineTrimmedLength(lineRange, ns: ns)
                if contentLen > 0 {
                    concealKeepingMetrics(storage, NSRange(location: lineRange.location, length: contentLen))
                }
            }
        }
    }

    // MARK: - Thematic break

    private static func thematicMatch(startLine: Int, endLine: Int, lineStarts: [Int], ns: NSString) -> Bool {
        guard endLine - startLine == 1 else { return false }
        let line = ns.substring(with: lineRange(startLine, lineStarts: lineStarts, ns: ns))
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return thematicPattern.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) != nil
    }

    private static func styleThematicBreak(
        startLine: Int, lineStarts: [Int], storage: NSTextStorage, ns: NSString, theme: Theme
    ) {
        let range = lineRange(startLine, lineStarts: lineStarts, ns: ns)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 12 * theme.scale
        style.paragraphSpacing = 12 * theme.scale
        storage.addAttribute(.paragraphStyle, value: style, range: range)
        storage.addAttribute(.marcoThematicBreak, value: NSNumber(value: true), range: range)
        // Hide the `---` run (keep the line's height); the fragment draws a
        // hairline rule across it instead.
        let contentLen = trailingNewlineTrimmedLength(range, ns: ns)
        if contentLen > 0 { concealKeepingMetrics(storage, NSRange(location: range.location, length: contentLen)) }
    }

    // MARK: - Concealment helpers

    /// A near-zero-point font so a marker keeps its characters in the store
    /// (display length == store length ⇒ native caret/selection/copy) while
    /// occupying no visible advance. This is the concealment mechanism M6-PLAN
    /// §1/§8-risk-5 prescribes; the substitution fallback was prototyped and
    /// rejected (length-changing `textParagraphWith:` halts TextKit 2 layout
    /// enumeration after the first fragment — verified headlessly).
    private static let concealFont = NSFont.systemFont(ofSize: 0.01)

    /// Zero-advance concealment: the marker vanishes with no residual gap
    /// (`## Heading` → `Heading`, `[t](u)` → `t`). Used for inline markers.
    private static func conceal(_ storage: NSTextStorage, _ range: NSRange) {
        guard range.length > 0 else { return }
        storage.addAttribute(.font, value: concealFont, range: range)
        storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
    }

    /// Invisible but metrics-preserving: the run keeps its height so the line
    /// still contributes a row (code-fence padding lines, the thematic-break
    /// line the fragment draws a rule across).
    private static func concealKeepingMetrics(_ storage: NSTextStorage, _ range: NSRange) {
        guard range.length > 0 else { return }
        storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
    }

    /// Conceals the opening delimiter (length `delimLength` at the content's
    /// left) and the closing delimiter (same length at the content's right) of
    /// an emphasis match whose group 2 is the content.
    private static func concealDelimiters(around match: NSTextCheckingResult, delimLength: Int, storage: NSTextStorage) {
        let whole = match.range
        let content = match.range(at: 2)
        conceal(storage, NSRange(location: whole.location, length: content.location - whole.location))
        let contentEnd = content.location + content.length
        conceal(storage, NSRange(location: contentEnd, length: whole.location + whole.length - contentEnd))
    }

    private static func concealFirstMatch(
        _ pattern: NSRegularExpression, inLine line: Int, lineStarts: [Int], storage: NSTextStorage, ns: NSString
    ) {
        concealFirstMatch(pattern, inLineRange: lineRange(line, lineStarts: lineStarts, ns: ns), storage: storage, ns: ns)
    }

    private static func concealFirstMatch(
        _ pattern: NSRegularExpression, inLineRange lineRange: NSRange, storage: NSTextStorage, ns: NSString
    ) {
        let text = ns.substring(with: lineRange)
        guard let m = pattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return }
        conceal(storage, NSRange(location: lineRange.location + m.range.location, length: m.range.length))
    }

    /// Styles one list line: hanging-indent paragraph style plus marker
    /// concealment. Unordered markers are concealed to zero width and a bullet
    /// is drawn by the fragment in the gutter; ordered markers keep their
    /// visible `N.` (only the leading indentation is concealed); continuation
    /// lines just inherit the indent.
    private static func styleListLine(lineRange: NSRange, text: String, storage: NSTextStorage, theme: Theme) {
        let level = listNestingLevel(text)
        let indent = CGFloat(level) * MarcoReadingMetrics.listIndent
        let hang = MarcoReadingMetrics.listHang
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6.5 * theme.scale
        style.headIndent = indent + hang
        let full = NSRange(location: 0, length: (text as NSString).length)

        if let m = ulMarkerPattern.firstMatch(in: text, range: full) {
            // Text (first + wrapped) aligns at indent+hang; the bullet sits in
            // the gutter at `indent`, drawn by the layout fragment.
            style.firstLineHeadIndent = indent + hang
            conceal(storage, NSRange(location: lineRange.location, length: m.range.length))
            storage.addAttribute(.marcoListBullet, value: NSNumber(value: Double(indent)),
                                 range: NSRange(location: lineRange.location, length: 1))
        } else if let m = olIndentPattern.firstMatch(in: text, range: full) {
            // Ordered: keep the visible `N.` in the gutter; conceal only indent.
            style.firstLineHeadIndent = indent
            conceal(storage, NSRange(location: lineRange.location, length: m.range.length))
        } else {
            style.firstLineHeadIndent = indent + hang
        }
        storage.addAttribute(.paragraphStyle, value: style, range: lineRange)
    }

    // MARK: - Images

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
            let lineRange = ns.lineRange(for: NSRange(location: match.range.location, length: 0))
            storage.addAttribute(.marcoImage, value: decoration, range: lineRange)
            // Conceal the `![alt](url)` markup (keep the line's newline).
            conceal(storage, match.range)
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

    private static func isFence(_ line: String) -> Bool {
        fencePattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
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
        for ch in line {
            if ch == ">" { depth += 1 }
            else if ch == " " || ch == "\t" { continue }
            else { break }
        }
        return depth
    }

    private static func trailingNewlineTrimmedLength(_ lineRange: NSRange, ns: NSString) -> Int {
        var len = lineRange.length
        while len > 0 {
            let ch = ns.character(at: lineRange.location + len - 1)
            if ch == 0x0A || ch == 0x0D { len -= 1 } else { break }
        }
        return len
    }

    private static func lineRange(_ line: Int, lineStarts: [Int], ns: NSString) -> NSRange {
        let s = lineStarts[line]
        let e = (line + 1) < lineStarts.count ? lineStarts[line + 1] : ns.length
        return NSRange(location: s, length: e - s)
    }

    private static func lineIndex(ofOffset offset: Int, lineStarts: [Int]) -> Int {
        // Binary search: largest lineStart <= offset.
        var lo = 0, hi = lineStarts.count - 1, result = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lineStarts[mid] <= offset { result = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return result
    }

    private static func eachLine(
        startLine: Int, endLine: Int, lineStarts: [Int], ns: NSString, _ body: (NSRange, Int) -> Void
    ) {
        for line in startLine..<endLine {
            guard line < lineStarts.count else { break }
            let s = lineStarts[line]
            let e = (line + 1) < lineStarts.count ? lineStarts[line + 1] : ns.length
            guard s < e else { continue }
            body(NSRange(location: s, length: e - s), line)
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
