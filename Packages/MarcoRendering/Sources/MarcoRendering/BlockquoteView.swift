import MarcoCore
import SwiftUI

/// A blockquote, styled the way Apple Notes / Pages set off a quotation:
/// quiet and typographic, not a web-style tinted card. It's an indented
/// text block in the secondary color, marked by a single thin, rounded
/// neutral rule down its leading edge — no fill, no accent, no border.
///
/// `model.children` render recursively via `StructuredChildView`, so a
/// heading, nested list, or code block inside a quote keeps its real block
/// type. A nested quote (`>>`) is just another `BlockquoteView` among those
/// children: it adds its own indent and one more rule, so depth reads as
/// progressively deeper indentation rather than cards stacked inside cards.
struct BlockquoteView: View {
    let model: QuoteModel
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 2px rule, rounded caps, spanning the full wrapped height of the
            // quoted content (a Shape in an HStack fills the row's height).
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(theme.quoteBar)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: theme.scaled(2)) {
                ForEach(model.children) { child in
                    StructuredChildView(child: child, textColor: theme.quoteText)
                }
            }
            .padding(.leading, theme.scaled(14))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Kept close to paragraph rhythm so a quote settles into the flow
        // instead of floating in a padded box.
        .padding(.vertical, theme.scaled(6))
    }
}
