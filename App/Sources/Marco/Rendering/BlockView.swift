import MarcoCore
import SwiftUI

/// Dispatches a parsed `Block` to the right typed view. One view per block
/// kind, keyed by `block.id` in the enclosing `LazyVStack`, so live reload
/// can reuse unchanged views.
struct BlockView: View {
    let block: Block

    var body: some View {
        // Publish this block's id so leaf text views (including ones nested in
        // list items / blockquotes) can form their ⌘F highlight key.
        content.environment(\.findBlockID, block.id)
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .frontmatter:
            FrontmatterView(raw: block.rawText)
        case .heading(let level):
            HeadingView(level: level, text: BlockStructureCache.shared.headingText(for: block))
        case .paragraph:
            ParagraphView(raw: block.rawText)
        case .codeBlock(let language):
            CodeBlockView(raw: block.rawText, language: language)
        case .list:
            if let model = BlockStructureCache.shared.list(for: block) {
                ListView(model: model)
                    .environment(\.checkboxBlockStartLine, block.startLine)
            } else {
                RawFallbackView(raw: block.rawText)
            }
        case .table:
            if let model = BlockStructureCache.shared.table(for: block) {
                TableBlockView(model: model)
            } else {
                RawFallbackView(raw: block.rawText)
            }
        case .blockquote:
            if let model = BlockStructureCache.shared.quote(for: block) {
                BlockquoteView(model: model)
                    .environment(\.checkboxBlockStartLine, block.startLine)
            } else {
                RawFallbackView(raw: block.rawText)
            }
        case .thematicBreak:
            ThematicBreakView()
        case .htmlBlock:
            HTMLBlockView(raw: block.rawText)
        }
    }
}

// MARK: - Heading

struct HeadingView: View {
    let level: Int
    let text: String
    /// `StructuredChild.id` when this heading is nested inside a list/quote;
    /// `nil` for a top-level heading. Part of its ⌘F highlight key.
    var childID: Int? = nil
    @Environment(\.theme) private var theme
    @Environment(\.findHighlight) private var findHighlight
    @Environment(\.findBlockID) private var findBlockID

    var body: some View {
        let style = theme.heading(level: level)
        // A heading nested inside a list item or blockquote (childID != nil)
        // gets compact vertical spacing — the container already supplies its
        // own rhythm, so the top-level heading ramp's generous margins would
        // otherwise blow the card open (e.g. an H2 heading inside a quote).
        let isNested = childID != nil
        let topPad = isNested ? min(style.spacingAbove, theme.scaled(4)) : style.spacingAbove
        let bottomPad = isNested ? min(style.spacingBelow, theme.scaled(4)) : style.spacingBelow
        let attributed = applyingFindHighlight(
            InlineMarkdown.attributed(text, theme: theme),
            context: findHighlight, blockID: findBlockID, childID: childID, theme: theme)
        Text(attributed)
            .font(style.font)
            .foregroundStyle(style.color)
            .tracking(style.tracking)
            .lineSpacing(style.lineSpacing)
            .textCase(style.uppercase ? .uppercase : nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, topPad)
            .padding(.bottom, bottomPad)
            .textSelection(.enabled)
            // VoiceOver reads the document as a structured outline: each
            // heading is announced as a heading at its real level, so
            // rotor "Headings" navigation and level nesting work (PLAN §6).
            .accessibilityAddTraits(.isHeader)
            .accessibilityHeading(Self.headingLevel(level))
    }

    private static func headingLevel(_ level: Int) -> AccessibilityHeadingLevel {
        switch level {
        case 1: return .h1
        case 2: return .h2
        case 3: return .h3
        case 4: return .h4
        case 5: return .h5
        default: return .h6
        }
    }
}

// MARK: - Paragraph

struct ParagraphView: View {
    let raw: String
    /// Overrides the text color (e.g. a completed task item, or muted
    /// blockquote prose) when this paragraph is rendered nested inside a
    /// list item or blockquote. `nil` keeps the default `textPrimary`.
    var textColor: Color? = nil
    /// `StructuredChild.id` when this paragraph is nested inside a list/quote;
    /// `nil` for a top-level paragraph. Part of its ⌘F highlight key.
    var childID: Int? = nil
    @Environment(\.theme) private var theme
    @Environment(\.findHighlight) private var findHighlight
    @Environment(\.findBlockID) private var findBlockID

    var body: some View {
        if let image = InlineImage.soleImage(in: raw) {
            ImageBlockView(alt: image.alt, source: image.source)
                .padding(.vertical, theme.scaled(8))
        } else {
            let attributed = applyingFindHighlight(
                InlineMarkdown.attributed(raw, theme: theme),
                context: findHighlight, blockID: findBlockID, childID: childID, theme: theme)
            Text(attributed)
                .font(theme.bodyFont)
                .foregroundStyle(textColor ?? theme.textPrimary)
                .lineSpacing(theme.bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, theme.scaled(7))
                .textSelection(.enabled)
        }
    }
}

// MARK: - Thematic break

struct ThematicBreakView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Capsule()
            .fill(theme.thematicBreak)
            .frame(width: 220, height: 1.5)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, theme.scaled(28))
    }
}

// MARK: - Raw fallback (defensive: a list/table/quote block whose text
// couldn't be re-parsed into a structured model)

struct RawFallbackView: View {
    let raw: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(raw)
            .font(theme.monoFont(12))
            .foregroundStyle(theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - HTML block (raw passthrough, monospaced + muted)

struct HTMLBlockView: View {
    let raw: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            .font(theme.monoFont(12))
            .foregroundStyle(theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, theme.scaled(6))
            .textSelection(.enabled)
    }
}
