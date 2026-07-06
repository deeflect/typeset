import MarcoCore
import SwiftUI

/// Renders ordered / unordered / task lists from a `ListModel` built by
/// `BlockStructure` off the real cmark-gfm AST: true nested depth (each
/// level recurses into another `ListView` through `StructuredChildView`),
/// correct ordered-list start/numbering, and loose/tight item spacing —
/// rather than depth guessed from raw leading spaces. Task checkboxes get
/// real checkbox visuals but are non-interactive this milestone
/// (write-back lands in M3).
struct ListView: View {
    let model: ListModel
    /// Nesting level, purely to vary the bullet glyph (•, ◦, ▪ …) the way
    /// GitHub does. Indentation itself falls out of each level's own
    /// marker + content `HStack` — no separate offset needed.
    var depth: Int = 0
    @Environment(\.theme) private var theme

    private var itemSpacing: CGFloat { theme.scaled(model.isLoose ? 12 : 4) }
    private var childSpacing: CGFloat { theme.scaled(model.isLoose ? 8 : 4) }

    var body: some View {
        VStack(alignment: .leading, spacing: itemSpacing) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: theme.scaled(8)) {
                    marker(for: item, number: model.start + index)
                    VStack(alignment: .leading, spacing: childSpacing) {
                        ForEach(item.children) { child in
                            StructuredChildView(
                                child: child,
                                textColor: textColor(for: item.checkbox),
                                listDepth: depth)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, depth == 0 ? theme.scaled(8) : 0)
    }

    private func textColor(for checkbox: TaskState?) -> Color? {
        checkbox == .checked ? theme.textSecondary : nil
    }

    @ViewBuilder
    private func marker(for item: ListModel.Item, number: Int) -> some View {
        if let checkbox = item.checkbox {
            Image(systemName: checkbox == .checked ? "checkmark.square.fill" : "square")
                .font(.system(size: theme.bodySize * theme.scale, weight: .regular))
                .foregroundStyle(checkbox == .checked ? theme.accent : theme.textTertiary)
                .frame(width: theme.scaled(20), alignment: .center)
        } else if model.isOrdered {
            Text("\(number).")
                .font(theme.bodyFont.monospacedDigit())
                .foregroundStyle(theme.textSecondary)
                .fixedSize()
                .frame(minWidth: theme.scaled(22), alignment: .trailing)
        } else {
            Text(bulletGlyph(depth: depth))
                .font(.system(size: theme.bodySize * theme.scale * bulletScale(depth)))
                .foregroundStyle(theme.textTertiary)
                .frame(width: theme.scaled(16), alignment: .center)
        }
    }

    private func bulletGlyph(depth: Int) -> String {
        switch depth % 3 {
        case 0: return "•"
        case 1: return "◦"
        default: return "▪"
        }
    }

    private func bulletScale(_ depth: Int) -> CGFloat {
        depth % 3 == 2 ? 0.7 : 1.0
    }
}
