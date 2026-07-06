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
enum InlineMarkdown {
    private struct Key: Hashable {
        let source: String
        let isDark: Bool
        let scale: CGFloat
    }

    @MainActor private static var cache: [Key: AttributedString] = [:]
    @MainActor private static let cacheLimit = 6000

    @MainActor
    static func attributed(_ source: String, theme: Theme) -> AttributedString {
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
    nonisolated static func plainText(_ source: String) -> String {
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
    static func invalidate() { cache.removeAll(keepingCapacity: true) }

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
        }
        for range in linkRanges {
            attributed[range].foregroundColor = theme.linkColor
        }
    }
}
