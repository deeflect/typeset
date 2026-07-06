import MarcoCore
import SwiftUI

/// Renders a GFM table as a bordered card: emphasized header row, hairline
/// row separators, hover highlight on body rows. When the table is wider
/// than the reading column it scrolls horizontally *inside* the card;
/// otherwise its columns share the available width. `model` comes from
/// `BlockStructure`'s AST walk, so a cell containing a pipe inside a code
/// span (`` `a|b` ``) is split correctly instead of on every raw `|`.
struct TableBlockView: View {
    let model: TableModel
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var availableWidth: CGFloat = 0
    @State private var hoveredRow: Int?

    private let minColumnWidth: CGFloat = 116

    var body: some View {
        card(for: model)
            .padding(.vertical, theme.scaled(10))
    }

    @ViewBuilder
    private func card(for model: TableModel) -> some View {
        let columns = model.header.count
        let colWidth = minColumnWidth * theme.scale
        // In snapshots (no live scroll capture) always lay columns out to
        // fit so the whole table is visible.
        let fits = isSnapshot || (availableWidth > 0 && CGFloat(columns) * colWidth <= availableWidth)

        let grid = VStack(spacing: 0) {
            row(model.header, isHeader: true, rowIndex: -1,
                alignments: model.alignments, fits: fits, colWidth: colWidth)
            ForEach(model.rows.indices, id: \.self) { i in
                Rectangle().fill(theme.tableStroke).frame(height: 1)
                row(model.rows[i], isHeader: false, rowIndex: i,
                    alignments: model.alignments, fits: fits, colWidth: colWidth)
            }
        }

        Group {
            if fits {
                grid
            } else {
                ScrollView(.horizontal, showsIndicators: true) { grid }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.tableStroke, lineWidth: 1)
        )
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { availableWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, new in availableWidth = new }
            }
        )
    }

    private func row(_ cells: [String], isHeader: Bool, rowIndex: Int,
                     alignments: [TableModel.Alignment], fits: Bool, colWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(cells.indices, id: \.self) { c in
                let alignment = c < alignments.count ? alignments[c] : .leading
                Text(InlineMarkdown.attributed(cells[c], theme: theme))
                    .font(isHeader ? theme.bodyFont.weight(.semibold) : theme.bodyFont)
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(textAlignment(alignment))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: fits ? nil : colWidth,
                           maxWidth: fits ? .infinity : nil,
                           alignment: frameAlignment(alignment))
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
            }
        }
        .background(background(isHeader: isHeader, rowIndex: rowIndex))
        .contentShape(Rectangle())
        .onHover { inside in
            guard !isHeader else { return }
            hoveredRow = inside ? rowIndex : (hoveredRow == rowIndex ? nil : hoveredRow)
        }
    }

    private func background(isHeader: Bool, rowIndex: Int) -> Color {
        if isHeader { return theme.tableHeaderFill }
        return hoveredRow == rowIndex ? theme.tableRowHoverFill : Color.clear
    }

    private func frameAlignment(_ a: TableModel.Alignment) -> Alignment {
        switch a {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func textAlignment(_ a: TableModel.Alignment) -> TextAlignment {
        switch a {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}
