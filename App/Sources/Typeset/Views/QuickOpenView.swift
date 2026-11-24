import SwiftUI
import TypesetRendering

/// Open Quickly (⌘K): a search field over the folder's Markdown files,
/// fuzzy-ranked by `FolderIndex.rank`. ↑/↓ move, Return opens, Esc closes.
struct QuickOpenView: View {
    let model: WindowModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var scanned: [FolderIndex.Entry] = []
    @State private var selection: URL?
    @FocusState private var fieldFocused: Bool

    /// Live list in folder mode; otherwise a one-off scan of the file's folder.
    private var files: [FolderIndex.Entry] { model.folder?.files ?? scanned }

    var body: some View {
        let results = FolderIndex.rank(query, in: files)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                TextField("Open Quickly", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($fieldFocused)
                    .onSubmit { open(selection ?? results.first?.url) }
                    .onKeyPress(.downArrow) { move(1, in: results) }
                    .onKeyPress(.upArrow) { move(-1, in: results) }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            Rectangle().fill(theme.hairline).frame(height: 1)
            if results.isEmpty {
                Text("No Matches")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(results) { file in
                                row(file, selected: file.url == selection).id(file.url)
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: selection) { _, url in if let url { proxy.scrollTo(url) } }
                }
                .frame(height: min(CGFloat(results.count) * 36 + 12, 308))
            }
        }
        .frame(width: 560)
        .onExitCommand { dismiss() }
        .onChange(of: query) { selection = FolderIndex.rank(query, in: files).first?.url }
        .task {
            if model.folder == nil, let root = model.quickOpenRoot {
                scanned = await Task.detached { FolderIndex.scan(root) }.value
            }
            selection = FolderIndex.rank(query, in: files).first?.url
            fieldFocused = true
        }
    }

    /// R07 result row: 8/10 padding, radius 6; selected = accent fill, white text.
    private func row(_ file: FolderIndex.Entry, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Text(highlighted(file.name))
                .font(.system(size: 13))
                .foregroundStyle(selected ? .white : .primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(file.folder)
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.white.opacity(0.8) : theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(selected ? theme.accent : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { open(file.url) }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Matched letters bold (R07).
    private func highlighted(_ name: String) -> AttributedString {
        var text = AttributedString(name)
        let chars = Array(text.characters.indices)
        for offset in FolderIndex.matchedOffsets(query, in: name) where offset < chars.count {
            text[chars[offset]..<text.characters.index(after: chars[offset])].font = .system(size: 13, weight: .bold)
        }
        return text
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
