import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MarcoRendering

/// Board 07: shown only when no document is open. Identity and Open… on the
/// left, recents on the right, and the whole window is the drop target.
struct EmptyStateView: View {
    @Environment(\.theme) private var theme
    @State private var recents = RecentDocumentsStore.shared
    @State private var isTargeted = false

    private var appDelegate: AppDelegate? { NSApp.delegate as? AppDelegate }
    private let markdownExtensions = ["md", "markdown", "mdown"]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                intro.frame(minWidth: 300, maxWidth: .infinity)
                recentsPane.frame(width: 360)
            }
            intro
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        .overlay {
            Rectangle()
                .strokeBorder(isTargeted ? theme.accent : .clear, lineWidth: 2)
                .animation(Theme.Motion.feedback, value: isTargeted)
                .allowsHitTesting(false)
        }
        .dropDestination(for: URL.self) { urls, _ in open(dropped: urls) } isTargeted: { isTargeted = $0 }
    }

    private var intro: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(Bundle.main.displayName)
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.48)
                    .foregroundStyle(theme.textPrimary)
                Text(isTargeted ? "Drop to open" : "Open a Markdown file to read it")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .contentTransition(.opacity)
            }
            Button { appDelegate?.openPanel() } label: {
                HStack(spacing: 8) {
                    Text("Open…").font(.system(size: 13, weight: .medium))
                    Text("⌘O").font(.system(size: 12)).opacity(0.7)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(theme.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .keyboardShortcut(.defaultAction)
            Text("or drop one here")
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(20)
        .frame(maxHeight: .infinity)
    }

    private var recentsPane: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(recents.entries) { entry in
                    RecentRow(entry: entry) { DocumentOpener.shared.open(entry.url) }
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
        }
        .overlay {
            if recents.entries.isEmpty {
                Text("No recent files").font(.system(size: 13)).foregroundStyle(theme.textTertiary)
            }
        }
        .frame(maxHeight: .infinity)
        .background(theme.sidebar)
        .overlay(alignment: .leading) { Rectangle().fill(theme.hairline).frame(width: 1) }
        .contextMenu {
            if !recents.entries.isEmpty { Button("Clear Recents") { recents.clear() } }
        }
    }

    private func open(dropped urls: [URL]) -> Bool {
        guard let url = urls.first(where: { markdownExtensions.contains($0.pathExtension.lowercased()) || $0.isDirectory }) else {
            return false
        }
        DocumentOpener.shared.open(url)
        return true
    }
}

/// One recent file: name over abbreviated folder, 44 pt, accent fill on hover.
private struct RecentRow: View {
    let entry: RecentDocumentsStore.Entry
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(hovering ? Color.white : Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(hovering ? Color.white : theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(entry.location)
                        .font(.system(size: 11))
                        .foregroundStyle(hovering ? Color.white.opacity(0.8) : theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background(hovering ? theme.accent : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .help(entry.url.path)
        .accessibilityLabel("\(entry.name), in \(entry.location)")
    }
}
