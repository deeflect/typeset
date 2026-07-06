import SwiftUI

/// Renders ordered / unordered / task lists with tuned indentation and
/// marker typography. Task checkboxes get real checkbox visuals but are
/// non-interactive this milestone (write-back lands in M3).
struct ListView: View {
    let raw: String
    @Environment(\.theme) private var theme

    var body: some View {
        let rows = BlockParsing.listRows(raw)
        VStack(alignment: .leading, spacing: theme.scaled(4)) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: theme.scaled(8)) {
                    marker(for: row)
                    Text(InlineMarkdown.attributed(row.text, theme: theme))
                        .font(theme.bodyFont)
                        .foregroundStyle(textColor(for: row.marker))
                        .lineSpacing(theme.bodyLineSpacing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(.leading, CGFloat(row.depth) * theme.scaled(24))
            }
        }
        .padding(.vertical, theme.scaled(8))
    }

    private func textColor(for marker: BlockParsing.ListMarker) -> Color {
        if case .task(let checked) = marker, checked { return theme.textSecondary }
        return theme.textPrimary
    }

    @ViewBuilder
    private func marker(for row: BlockParsing.ListRow) -> some View {
        switch row.marker {
        case .bullet:
            Text(bulletGlyph(depth: row.depth))
                .font(.system(size: theme.bodySize * theme.scale * bulletScale(row.depth)))
                .foregroundStyle(theme.textTertiary)
                .frame(width: theme.scaled(16), alignment: .center)
        case .ordered(let n):
            Text("\(n).")
                .font(theme.bodyFont.monospacedDigit())
                .foregroundStyle(theme.textSecondary)
                .frame(width: theme.scaled(22), alignment: .trailing)
        case .task(let checked):
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: theme.bodySize * theme.scale, weight: .regular))
                .foregroundStyle(checked ? theme.accent : theme.textTertiary)
                .frame(width: theme.scaled(20), alignment: .center)
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
