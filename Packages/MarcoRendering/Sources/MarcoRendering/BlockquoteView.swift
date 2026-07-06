import MarcoCore
import SwiftUI

/// A blockquote: tinted card with an accent bar on the left, rendering
/// `model.children` recursively via `StructuredChildView` — so a heading,
/// nested list, or nested code block inside a quote all render as their
/// real block type instead of flattening to a paragraph. A nested quote
/// (`>>`) is just another `BlockquoteView` rendered as one of those
/// children, which naturally deepens the look (its own bar + tint nested
/// inside the outer one).
struct BlockquoteView: View {
    let model: QuoteModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.scaled(4)) {
            ForEach(model.children) { child in
                StructuredChildView(child: child, textColor: theme.quoteText)
            }
        }
        .padding(.vertical, theme.scaled(12))
        .padding(.horizontal, theme.scaled(16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.quoteFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(theme.quoteBar)
                .frame(width: 3)
                .padding(.vertical, theme.scaled(12))
        }
        .padding(.vertical, theme.scaled(9))
    }
}
