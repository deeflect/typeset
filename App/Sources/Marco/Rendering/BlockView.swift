import MarcoCore
import SwiftUI

/// Dispatches a parsed `Block` to the right typed view. One view per block
/// kind, keyed by `block.id` in the enclosing `LazyVStack`, so live reload
/// can reuse unchanged views.
struct BlockView: View {
    let block: Block

    var body: some View {
        switch block.kind {
        case .frontmatter:
            FrontmatterView(raw: block.rawText)
        case .heading(let level):
            HeadingView(level: level, raw: block.rawText)
        case .paragraph:
            ParagraphView(raw: block.rawText)
        case .codeBlock(let language):
            CodeBlockView(raw: block.rawText, language: language)
        case .list:
            ListView(raw: block.rawText)
        case .table:
            TableBlockView(raw: block.rawText)
        case .blockquote:
            BlockquoteView(raw: block.rawText)
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
    let raw: String
    @Environment(\.theme) private var theme

    var body: some View {
        let style = theme.heading(level: level)
        Text(InlineMarkdown.attributed(BlockParsing.headingText(raw), theme: theme))
            .font(style.font)
            .foregroundStyle(style.color)
            .tracking(style.tracking)
            .lineSpacing(style.lineSpacing)
            .textCase(style.uppercase ? .uppercase : nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, style.spacingAbove)
            .padding(.bottom, style.spacingBelow)
            .textSelection(.enabled)
    }
}

// MARK: - Paragraph

struct ParagraphView: View {
    let raw: String
    @Environment(\.theme) private var theme

    var body: some View {
        if let image = InlineImage.soleImage(in: raw) {
            ImageBlockView(alt: image.alt, source: image.source)
                .padding(.vertical, theme.scaled(8))
        } else {
            Text(InlineMarkdown.attributed(raw, theme: theme))
                .font(theme.bodyFont)
                .foregroundStyle(theme.textPrimary)
                .lineSpacing(theme.bodyLineSpacing)
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
