import AppKit
import SwiftUI

/// A fenced (or indented) code block rendered as a rounded card: subtle
/// fill + hairline stroke, SF Mono, horizontal scroll contained *inside*
/// the card, and a language label plus copy button that materialize on
/// hover. Syntax highlighting is computed off-main and cached.
struct CodeBlockView: View {
    let raw: String
    let language: String?
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    @State private var highlighted: AttributedString?
    @State private var hovering = false
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    private var code: String { CodeBlockView.extractCode(raw) }

    var body: some View {
        let initial = highlighted
            ?? CodeHighlighter.shared.cached(code: code, language: language, isDark: theme.colorScheme == .dark)
        let displayed: AttributedString = initial ?? AttributedString(code)
        let isHighlighted = initial != nil

        codeText(displayed, isHighlighted: isHighlighted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.codeCardFill)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.codeCardStroke, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) { chrome }
        .padding(.vertical, theme.scaled(10))
        .onHover { hovering = $0 }
        .task(id: highlightKey) {
            highlighted = await CodeHighlighter.shared.highlighted(
                code: code, language: language, isDark: theme.colorScheme == .dark)
        }
    }

    @ViewBuilder
    private func codeText(_ displayed: AttributedString, isHighlighted: Bool) -> some View {
        let text = Text(displayed)
            .font(theme.codeBlockFont)
            .foregroundStyle(isHighlighted ? Color.primary : theme.textPrimary)
            .textSelection(.enabled)

        if isSnapshot {
            // ImageRenderer can't capture ScrollView content; wrap instead.
            text
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                text
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(minWidth: 0, alignment: .leading)
            }
        }
    }

    private var highlightKey: String {
        "\(code.hashValue)|\(language ?? "")|\(theme.colorScheme == .dark)"
    }

    @ViewBuilder
    private var chrome: some View {
        HStack(spacing: 8) {
            if let language, !language.isEmpty {
                Text(language.uppercased())
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(theme.textTertiary)
                    .opacity(hovering ? 0.55 : 0.85)
            }
            copyButton
                .opacity(hovering ? 1 : 0)
        }
        .padding(.top, 9)
        .padding(.trailing, 12)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var copyButton: some View {
        Button {
            copy()
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(copied ? Color.green : theme.textSecondary)
                .frame(width: 22, height: 20)
                .background(theme.chipFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help("Copy code")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { copied = true }
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { copied = false }
        }
    }

    /// Strips fence lines (``` / ~~~) or dedents an indented code block.
    static func extractCode(_ raw: String) -> String {
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else { return raw }
        let trimmedFirst = first.trimmingCharacters(in: .whitespaces)
        if trimmedFirst.hasPrefix("```") || trimmedFirst.hasPrefix("~~~") {
            lines.removeFirst()
            if let last = lines.last?.trimmingCharacters(in: .whitespaces),
               last.hasPrefix("```") || last.hasPrefix("~~~") {
                lines.removeLast()
            }
            return lines.joined(separator: "\n")
        }
        // Indented code block: strip up to 4 leading spaces / one tab.
        return lines.map { line -> String in
            if line.hasPrefix("    ") { return String(line.dropFirst(4)) }
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            return line
        }.joined(separator: "\n")
    }
}
