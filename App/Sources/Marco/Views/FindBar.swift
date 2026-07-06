import SwiftUI

/// The ⌘F in-window find bar: a glass strip that slides in under the toolbar.
/// Case-insensitive by default, live match count ("3 of 17"), next/prev
/// (also ⌘G / ⌘⇧G and return / shift-return), Esc to dismiss. Highlighting of
/// the matches themselves happens in the block views via the `findHighlight`
/// environment; this bar only drives the query and the current index.
struct FindBar: View {
    let model: WindowModel
    @Environment(\.theme) private var theme
    @FocusState private var fieldFocused: Bool

    private var find: FindSession { model.find }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))

            TextField("Find", text: Binding(
                get: { find.query },
                set: { find.setQuery($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($fieldFocused)
                .frame(minWidth: 160)
                .onKeyPress { press in
                    switch press.key {
                    case .return:
                        if press.modifiers.contains(.shift) { model.findPrevious() } else { model.findNext() }
                        return .handled
                    default:
                        return .ignored
                    }
                }

            if !find.statusText.isEmpty {
                Text(find.statusText)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            Toggle(isOn: Binding(
                get: { find.caseSensitive },
                set: { find.caseSensitive = $0 })) {
                Text("Aa").font(.system(size: 12, weight: .semibold))
            }
            .toggleStyle(.button)
            .help("Match Case")

            Divider().frame(height: 16)

            Button { model.findPrevious() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain)
                .disabled(find.matchCount == 0)
                .help("Previous Match (⇧⌘G)")
            Button { model.findNext() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
                .disabled(find.matchCount == 0)
                .help("Next Match (⌘G)")

            Button { model.closeFind() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Done (Esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.chipStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .frame(maxWidth: 520, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onExitCommand { model.closeFind() }
        .onAppear { fieldFocused = true }
    }
}
