import MarcoCore
import SwiftUI

/// Board 02: the heading outline as a stock sidebar list. Selection follows
/// the scroll position; picking a row jumps there.
struct OutlineSidebar: View {
    let model: WindowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let items = model.outlineItems
        List(selection: Binding(
            get: { model.currentOutlineID },
            set: { id in if let id { model.scrollToHeading(id, reduceMotion: reduceMotion) } }
        )) {
            Section("Outline") {
                if items.isEmpty {
                    Text("No headings").foregroundStyle(.tertiary)
                }
                ForEach(items) { item in
                    Text(item.title)
                        .font(.system(size: 13))
                        .foregroundStyle(item.depth >= 2 ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, CGFloat(item.depth) * 12)
                        .tag(Optional(item.id))
                }
            }
        }
        .listStyle(.sidebar)
    }
}
