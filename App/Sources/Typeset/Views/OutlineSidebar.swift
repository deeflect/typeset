import TypesetCore
import TypesetRendering
import SwiftUI

/// Board 02: the heading outline as a stock sidebar list. Selection follows
/// the scroll position; picking a row jumps there. In folder mode a Files
/// section (R07) sits above it: the current file tinted, a click navigates.
struct OutlineSidebar: View {
    let model: WindowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filesExpanded = true

    private enum Row: Hashable {
        case heading(String)
    }

    /// File rows draw their own current/hover fill (R07), so only headings use List selection.
    private var selection: Binding<Set<Row>> {
        Binding(
            get: { model.currentOutlineID.map { [.heading($0)] } ?? [] },
            set: { rows in
                for case .heading(let id) in rows where id != model.currentOutlineID {
                    model.scrollToHeading(id, reduceMotion: reduceMotion)
                    return
                }
            })
    }

    var body: some View {
        let items = model.outlineItems
        List(selection: selection) {
            if let folder = model.folder {
                Section(isExpanded: $filesExpanded) {
                    ForEach(folder.files) { file in
                        FileRow(file: file, rootName: folder.root.lastPathComponent,
                                isCurrent: file.url == model.currentURL?.standardizedFileURL) {
                            model.navigate(to: file.url)
                        }
                    }
                } header: {
                    SectionHeader(title: "Files \u{00B7} \(folder.root.lastPathComponent)")
                }
            }
            Section {
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
            } header: {
                SectionHeader(title: "Outline")
            }
        }
        .listStyle(.sidebar)
    }
}

/// R07: 11 pt semibold, tertiary.
private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// R07 file row: 5/8 padding, radius 6; current file accent-soft (name medium), hover 4% fill.
private struct FileRow: View {
    let file: FolderIndex.Entry
    let rootName: String
    let isCurrent: Bool
    let open: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(file.name)
                .font(.system(size: 13, weight: isCurrent ? .medium : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(file.folder.isEmpty ? rootName : file.folder)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? theme.accentSoft : hovered ? theme.rowHoverFill : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(reduceMotion ? nil : Theme.Motion.feedback) { hovered = inside } }
        .onTapGesture { if !isCurrent { open() } }
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
        .help(file.relativePath)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}
