import SwiftUI

/// A blockquote: tinted card with an accent bar on the left. Nested quotes
/// (`>>`) deepen by stacking additional bars.
struct BlockquoteView: View {
    let raw: String
    @Environment(\.theme) private var theme

    var body: some View {
        let paragraphs = BlockParsing.quoteParagraphs(raw)
        VStack(alignment: .leading, spacing: theme.scaled(8)) {
            ForEach(paragraphs) { paragraph in
                Text(InlineMarkdown.attributed(paragraph.text, theme: theme))
                    .font(theme.bodyFont)
                    .foregroundStyle(theme.quoteText)
                    .lineSpacing(theme.bodyLineSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, leadingInset(paragraph.depth))
                    .overlay(alignment: .leading) { bars(depth: paragraph.depth) }
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, theme.scaled(12))
        .padding(.horizontal, theme.scaled(16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.quoteFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.vertical, theme.scaled(9))
    }

    private func leadingInset(_ depth: Int) -> CGFloat {
        // `depth` is the raw `>` count (1 for a normal quote).
        theme.scaled(16) + CGFloat(max(0, depth - 1)) * theme.scaled(10)
    }

    private func bars(depth: Int) -> some View {
        HStack(spacing: theme.scaled(6)) {
            ForEach(0..<max(1, depth), id: \.self) { _ in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(theme.quoteBar)
                    .frame(width: 3)
            }
        }
    }
}
