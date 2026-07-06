import AppKit

/// Lightweight regex-based Markdown syntax styling for the M3 source editor
/// (PLAN §2 J4): headings bolder/bigger, links tinted, inline code/fences
/// tinted, bold/italic markers subtly dimmed. Deliberately not a real
/// parser — this is decoration on top of a plain-text `NSTextView`, applied
/// to an `NSTextStorage` directly.
///
/// Two entry points:
/// - `styleFullDocument` — whole-document pass, used on load and on
///   appearance change.
/// - `styleEdited` — incremental pass over just the edited paragraph
///   range, used from the `NSTextStorageDelegate` callback so typing never
///   waits on a whole-document restyle.
///
/// Both degrade gracefully above `largeDocumentThreshold`: full-document
/// restyling (and fence-state tracking, which needs a whole-document scan)
/// is skipped, leaving large files plain rather than blocking typing —
/// PLAN's "on 1MB+ files degrade gracefully" requirement. Typical files
/// (the common case: READMEs, CLAUDE.md, specs) stay fully styled.
enum MarkdownSyntaxStyler {
    /// Above this size (UTF-16 length), skip whole-document (re)styling and
    /// fence-state tracking. Fence tracking's whole-document line scan is
    /// the dominant cost of an incremental (per-keystroke) restyle — at
    /// 200 KB it measured ~12ms, noticeably short of "instant". 120 KB
    /// keeps that comfortably sub-frame while still covering the large
    /// majority of real READMEs/CLAUDE.md files; true 1 MB+ files (PLAN's
    /// explicit degrade-gracefully case) are far above it either way.
    static let largeDocumentThreshold = 120_000

    struct Colors {
        let heading: NSColor
        let link: NSColor
        let code: NSColor
        let codeBackground: NSColor
        let dim: NSColor
    }

    // MARK: - Entry points

    /// Whole-document restyle: on load, or when appearance/theme changes.
    static func styleFullDocument(_ storage: NSTextStorage, baseFont: NSFont, colors: Colors) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }
        resetAttributes(storage, range: full, baseFont: baseFont)
        guard full.length <= largeDocumentThreshold else { return }
        let text = storage.string as NSString
        let fenceLines = fenceLineSet(in: text)
        applyStyles(storage, text: text, range: full, baseFont: baseFont, colors: colors, fenceLines: fenceLines)
    }

    /// Incremental restyle over just the paragraph(s) touched by `editedRange`.
    static func styleEdited(_ storage: NSTextStorage, editedRange: NSRange, baseFont: NSFont, colors: Colors) {
        guard storage.length > 0 else { return }
        let text = storage.string as NSString
        // `editedRange` can be zero-length (pure deletion) or run past the
        // current length by construction of `NSTextStorageDelegate`'s
        // edited-range reporting; clamp defensively.
        let clamped = NSRange(
            location: min(editedRange.location, text.length),
            length: min(editedRange.length, max(0, text.length - editedRange.location)))
        let paragraphRange = text.paragraphRange(for: clamped)
        guard paragraphRange.length > 0 else { return }
        resetAttributes(storage, range: paragraphRange, baseFont: baseFont)

        let fenceLines: Set<Int>?
        if text.length <= largeDocumentThreshold {
            fenceLines = fenceLineSet(in: text)
        } else {
            // Degrade: no whole-document fence-state scan on huge files —
            // headings/links/inline code within the edited paragraph still
            // light up (cheap, local-only regex work), just without fence
            // background tinting.
            fenceLines = nil
        }
        applyStyles(storage, text: text, range: paragraphRange, baseFont: baseFont, colors: colors, fenceLines: fenceLines)
    }

    // MARK: - Base attributes

    private static func resetAttributes(_ storage: NSTextStorage, range: NSRange, baseFont: NSFont) {
        storage.setAttributes([.font: baseFont, .foregroundColor: NSColor.textColor], range: range)
    }

    // MARK: - Fence tracking

    /// Line indices (0-based) that fall strictly between a `` ``` ``/`~~~`
    /// open and its matching close (the fence marker lines themselves are
    /// also included) — used to tint fenced code regions distinctly from
    /// prose. A whole-document, single O(n) line scan; only run when the
    /// document is under `largeDocumentThreshold`.
    private static func fenceLineSet(in text: NSString) -> Set<Int> {
        var result: Set<Int> = []
        var inFence = false
        var fenceStart = 0
        var lineIndex = 0
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let line = text.substring(with: lineRange).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if inFence {
                    result.insert(lineIndex)
                    for i in fenceStart...lineIndex { result.insert(i) }
                    inFence = false
                } else {
                    inFence = true
                    fenceStart = lineIndex
                }
            }
            lineIndex += 1
        }
        return result
    }

    // MARK: - Regex styling

    private static let headingPattern = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+.*$"#, options: [.anchorsMatchLines])
    private static let linkPattern = try! NSRegularExpression(pattern: #"\[[^\]\n]*\]\([^)\n]*\)"#)
    private static let inlineCodePattern = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)
    private static let boldPattern = try! NSRegularExpression(pattern: #"(\*\*|__)([^\n]+?)\1"#)
    private static let italicPattern = try! NSRegularExpression(pattern: #"(?<![*_])([*_])([^\n*_]+?)\1(?![*_])"#)
    private static let strikePattern = try! NSRegularExpression(pattern: #"(~~)([^\n]+?)~~"#)

    private static func applyStyles(
        _ storage: NSTextStorage, text: NSString, range: NSRange, baseFont: NSFont,
        colors: Colors, fenceLines: Set<Int>?
    ) {
        if let fenceLines {
            styleFences(storage, text: text, range: range, colors: colors, fenceLines: fenceLines)
        }

        headingPattern.enumerateMatches(in: text as String, range: range) { match, _, _ in
            guard let match, let full = Range(match.range, in: text as String) else { return }
            let level = (text as String)[full].prefix(while: { $0 == "#" }).count
            let size = baseFont.pointSize + CGFloat(max(0, 5 - level))
            let font = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
            storage.addAttribute(.font, value: font, range: match.range)
            storage.addAttribute(.foregroundColor, value: colors.heading, range: match.range)
        }

        linkPattern.enumerateMatches(in: text as String, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.foregroundColor, value: colors.link, range: match.range)
        }

        inlineCodePattern.enumerateMatches(in: text as String, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.foregroundColor, value: colors.code, range: match.range)
            storage.addAttribute(.backgroundColor, value: colors.codeBackground, range: match.range)
        }

        boldPattern.enumerateMatches(in: text as String, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.font, value: NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask), range: match.range(at: 2))
            dimDelimiters(storage, match: match, delimiterGroup: 1, colors: colors, text: text)
        }

        italicPattern.enumerateMatches(in: text as String, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.font, value: NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask), range: match.range(at: 2))
            dimDelimiters(storage, match: match, delimiterGroup: 1, colors: colors, text: text)
        }

        strikePattern.enumerateMatches(in: text as String, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: match.range(at: 2))
            dimDelimiters(storage, match: match, delimiterGroup: 1, colors: colors, text: text)
        }
    }

    private static func styleFences(_ storage: NSTextStorage, text: NSString, range: NSRange, colors: Colors, fenceLines: Set<Int>) {
        guard !fenceLines.isEmpty else { return }
        var lineIndex = 0
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            defer { lineIndex += 1 }
            guard fenceLines.contains(lineIndex) else { return }
            guard let overlap = lineRange.intersection(range) else { return }
            storage.addAttribute(.foregroundColor, value: colors.code, range: overlap)
            storage.addAttribute(.backgroundColor, value: colors.codeBackground, range: overlap)
        }
    }

    /// Dims a matched delimiter pair (e.g. the two `**`s around bold text)
    /// found at capture group `delimiterGroup`, which regex matches on
    /// both sides of the content group.
    private static func dimDelimiters(_ storage: NSTextStorage, match: NSTextCheckingResult, delimiterGroup: Int, colors: Colors, text: NSString) {
        let delimiter = match.range(at: delimiterGroup)
        guard delimiter.location != NSNotFound else { return }
        let contentEnd = match.range(at: delimiterGroup + 1).location + match.range(at: delimiterGroup + 1).length
        let openRange = NSRange(location: match.range.location, length: delimiter.length)
        let closeRange = NSRange(location: contentEnd, length: delimiter.length)
        storage.addAttribute(.foregroundColor, value: colors.dim, range: openRange)
        if closeRange.location + closeRange.length <= text.length {
            storage.addAttribute(.foregroundColor, value: colors.dim, range: closeRange)
        }
    }
}
