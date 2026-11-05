import SwiftUI

/// Open Quickly (⌘K): a search field over the folder's Markdown files,
/// fuzzy-ranked by `FolderIndex.rank`. ↑/↓ move, Return opens, Esc closes.
struct QuickOpenView: View {
    let model: WindowModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var scanned: [FolderIndex.Entry] = []
    @State private var selection: URL?
    @FocusState private var fieldFocused: Bool

    /// Live list in folder mode; otherwise a one-off scan of the file's folder.
    private var files: [FolderIndex.Entry] { model.folder?.files ?? scanned }
    private var results: [FolderIndex.Entry] { FolderIndex.rank(query, in: files) }

    var body: some View {
        let results = results
        VStack(spacing: 0) {
            TextField("Open Quickly", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .padding(12)
                .focused($fieldFocused)
                .onSubmit { open(selection ?? results.first?.url) }
                .onKeyPress(.downArrow) { move(1, in: results) }
                .onKeyPress(.upArrow) { move(-1, in: results) }
            Divider()
            ScrollViewReader { proxy in
                List(results, selection: Binding(get: { selection }, set: { open($0) })) { file in
                    HStack(spacing: 8) {
                        Text(file.name).lineLimit(1)
                        Text(file.folder)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .tag(Optional(file.url))
                    .id(file.url)
                }
                .onChange(of: selection) { _, url in if let url { proxy.scrollTo(url) } }
            }
            .overlay {
                if results.isEmpty { Text("No Matches").foregroundStyle(.secondary) }
            }
        }
        .frame(width: 560, height: 360)
        .onExitCommand { dismiss() }
        .onChange(of: query) { selection = FolderIndex.rank(query, in: files).first?.url }
        .task {
            if model.folder == nil, let root = model.quickOpenRoot {
                scanned = await Task.detached { FolderIndex.scan(root) }.value
            }
            selection = results.first?.url
            fieldFocused = true
        }
    }

    private func move(_ step: Int, in results: [FolderIndex.Entry]) -> KeyPress.Result {
        guard !results.isEmpty else { return .handled }
        let current = results.firstIndex { $0.url == selection } ?? -step
        selection = results[min(max(current + step, 0), results.count - 1)].url
        return .handled
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        dismiss()
        model.navigate(to: url)
    }
}
