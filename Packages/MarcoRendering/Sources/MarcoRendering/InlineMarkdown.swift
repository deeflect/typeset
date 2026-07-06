import SwiftUI

/// Converts a block's inline Markdown source (bold / italic / links /
/// inline code / strikethrough) into a styled `AttributedString`.
///
/// Uses Foundation's `AttributedString(markdown:)` with
/// `.inlineOnlyPreservingWhitespace` so block syntax is treated literally —
/// callers strip block markers (`#`, `>`, list bullets) first. Bold,
/// italic, and strikethrough render automatically from the parsed
/// `inlinePresentationIntent`; we layer on the tinted inline-code background
/// and accent link color to match the theme.
///
/// Results are cached by (source, appearance, scale) because
/// `AttributedString(markdown:)` is the per-block hot path on large
/// documents — this keeps 1 MB scrolling smooth.
public enum InlineMarkdown {
    private struct Key: Hashable {
        let source: String
        let isDark: Bool
        let scale: CGFloat
    }

    @MainActor private static var cache: [Key: AttributedString] = [:]
    @MainActor private static let cacheLimit = 6000

    @MainActor
    public static func attributed(_ source: String, theme: Theme) -> AttributedString {
        let key = Key(source: source, isDark: theme.colorScheme == .dark, scale: theme.scale)
        if let hit = cache[key] { return hit }

        var attributed = parseInline(source)
        style(&attributed, theme: theme)

        if cache.count > cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = attributed
        return attributed
    }

    /// The plain (unstyled) rendered characters of a block's inline source —
    /// exactly the `Character` sequence that `attributed(_:theme:)` above
    /// produces, minus the color/background attributes. Because styling only
    /// *adds attributes* and never changes the characters, this is the
    /// authoritative searchable text for ⌘F: the offsets a find match reports
    /// against this string are valid indices into the rendered `Text`'s
    /// `AttributedString`. Theme-independent, so the find index can be built
    /// off the main actor / without a `Theme` in hand.
    nonisolated public static func plainText(_ source: String) -> String {
        String(parseInline(source).characters)
    }

    /// Shared inline parse (soft-break normalization + Foundation Markdown
    /// inline parsing). No theme, no styling — the character content only.
    nonisolated private static func parseInline(_ source: String) -> AttributedString {
        let normalized = normalizeSoftBreaks(source)
        do {
            return try AttributedString(
                markdown: normalized,
                options: AttributedString.MarkdownParsingOptions(
                    allowsExtendedAttributes: true,
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible))
        } catch {
            return AttributedString(source)
        }
    }

    /// Collapses Markdown *soft* line breaks (a lone `\n`) into spaces so
    /// prose reflows to the reading measure, while preserving explicit hard
    /// breaks (a line ending in two spaces or a backslash). We keep
    /// `.inlineOnlyPreservingWhitespace` for its faithful inline handling
    /// and just normalize the wrapping here.
    private static func normalizeSoftBreaks(_ source: String) -> String {
        guard source.contains("\n") else { return source }
        let lines = source.components(separatedBy: "\n")
        var result = ""
        for (index, line) in lines.enumerated() {
            if index == 0 {
                result = line
                continue
            }
            if result.hasSuffix("  ") || result.hasSuffix("\\") {
                result += "\n" + line
            } else {
                let trimmedLeading = String(line.drop(while: { $0 == " " || $0 == "\t" }))
                result += " " + trimmedLeading
            }
        }
        return result
    }

    /// Drop the cache when the appearance flips so stale colors never show.
    @MainActor
    public static func invalidate() { cache.removeAll(keepingCapacity: true) }

    @MainActor
    private static func style(_ attributed: inout AttributedString, theme: Theme) {
        // Collect ranges first — mutating while iterating `runs` is unsafe.
        var codeRanges: [Range<AttributedString.Index>] = []
        var linkRanges: [Range<AttributedString.Index>] = []
        for run in attributed.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                codeRanges.append(run.range)
            }
            if run.link != nil {
                linkRanges.append(run.range)
            }
        }
        for range in codeRanges {
            // Leave the font alone: the `.code` intent already renders
            // monospaced and inherits the surrounding size, so inline code
            // scales with headings/body. We only tint it.
            attributed[range].backgroundColor = theme.inlineCodeFill
            attributed[range].foregroundColor = theme.inlineCodeText
            // Telegram-style click-to-copy: carry the span's text on a custom
            // `marco-copy://` link the app resolves by copying to the
            // pasteboard. Set *after* `linkRanges` is collected above so this
            // synthetic link never gets the accent link tint — the code chip
            // styling stays, and the pointing-hand cursor is the affordance.
            // Foreground stays `inlineCodeText` (set here), overriding the
            // default link color. In Quick Look (no `openURL` handler) it is
            // an inert no-op.
            if let url = InlineCodeCopy.url(for: String(attributed[range].characters)) {
                attributed[range].link = url
            }
        }
        for range in linkRanges {
            attributed[range].foregroundColor = theme.linkColor
        }
    }
}

/// Shared contract for the click-to-copy inline-code affordance: the writer
/// (`InlineMarkdown`) encodes a code span's text into a `marco-copy://` URL
/// attached as a link run; the app's reading view decodes it and copies to
/// the pasteboard. Kept in one place so both ends agree on the format. The
/// Quick Look extension renders the link but installs no handler, so it is a
/// harmless no-op there.
public enum InlineCodeCopy {
    public static let scheme = "marco-copy"

    /// Percent-encode everything but alphanumerics so `&`, `+`, `#`, spaces,
    /// etc. round-trip losslessly (avoids `URLComponents`' query quirks).
    public static func url(for code: String) -> URL? {
        let encoded = code.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URL(string: "\(scheme)://copy?t=\(encoded)")
    }

    /// The code text for a `marco-copy://` URL, or `nil` if it isn't one.
    public static func code(from url: URL) -> String? {
        guard url.scheme == scheme,
              let query = url.query, query.hasPrefix("t=") else { return nil }
        return String(query.dropFirst(2)).removingPercentEncoding
    }
}
