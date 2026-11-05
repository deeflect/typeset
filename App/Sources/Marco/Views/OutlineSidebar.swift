import MarcoCore
import SwiftUI

/// Board 02: the heading outline as a stock sidebar list. Selection follows
/// the scroll position; picking a row jumps there. In folder mode a Files
/// section sits above it: the current file selected, a pick navigates.
struct OutlineSidebar: View {
    let model: WindowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filesExpanded = true

    private enum Row: Hashable {
        case file(URL)
        case heading(String)
    }

    private var selection: Binding<Set<Row>> {
        Binding(
            get: {
                var rows = Set<Row>()
                if let url = model.currentURL, model.folder != nil { rows.insert(.file(url.standardizedFileURL)) }
                if let id = model.currentOutlineID { rows.insert(.heading(id)) }
                return rows
            },
            set: { rows in
                for row in rows {
                    switch row {
                    case .file(let url) where url != model.currentURL?.standardizedFileURL:
                        model.navigate(to: url)
                        return
                    case .heading(let id) where id != model.currentOutlineID:
                        model.scrollToHeading(id, reduceMotion: reduceMotion)
                        return
                    default: continue
                    }
                }
            })
    }

    var body: some View {
        let items = model.outlineItems
        List(selection: selection) {
            if let folder = model.folder {
                Section("Files", isExpanded: $filesExpanded) {
                    ForEach(folder.files) { file in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.name)
                                .font(.system(size: 13))
                                .lineLimit(1)
                            if !file.folder.isEmpty {
                                Text(file.folder)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                        .help(file.relativePath)
                        .tag(Row.file(file.url))
                    }
                }
            }
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
                        .tag(Row.heading(item.id))
                }
            }
        }
        .listStyle(.sidebar)
    }
}
