import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The no-document "home screen" (PLAN §6): a single centered glass card that
/// is the whole window when opened without a file. It carries the app's
/// identity, the two ways in (Open… / drop a file), and a recent-files list
/// backed by security-scoped bookmarks. Deliberately weightless — no library,
/// no onboarding, no chrome.
struct EmptyStateView: View {
    /// Snapshot-only: force the opaque (Reduce Transparency) surface, since
    /// `ImageRenderer` can't rasterize the live glass backdrop.
    var forceOpaque = false

    @Environment(\.openWindow) private var openWindow
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @State private var recents = RecentDocumentsStore.shared
    @State private var isTargeted = false

    private var reduceTransparency: Bool { forceOpaque || systemReduceTransparency }
    private var appDelegate: AppDelegate? { NSApp.delegate as? AppDelegate }

    private let markdownExtensions = ["md", "markdown", "mdown"]

    var body: some View {
        card
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background)
            .dropDestination(for: URL.self) { urls, _ in open(dropped: urls) } isTargeted: { isTargeted = $0 }
    }

    // MARK: - Card

    private var card: some View {
        VStack(spacing: 0) {
            header
            actions
            if !recents.entries.isEmpty {
                Divider().overlay(theme.chipStroke)
                    .padding(.horizontal, 4)
                recentsList
            }
        }
        .padding(28)
        .background {
            if reduceTransparency {
                // Reduce Transparency: swap the glass for an opaque surface so
                // the card never depends on a blurred backdrop for legibility.
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(theme.chipFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(theme.chipStroke, lineWidth: 1))
            }
        }
        .glassEffectIfAvailable(enabled: !reduceTransparency)
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isTargeted ? theme.accent : .clear, lineWidth: 2)
                .animation(.easeOut(duration: 0.15), value: isTargeted)
        }
        .padding(40)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)

            Text(Bundle.main.displayName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.textPrimary)

            Text(isTargeted ? "Drop to open" : "Open a Markdown file to read it, beautifully.")
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
        }
        .padding(.bottom, 20)
    }

    // MARK: - Primary actions

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                appDelegate?.openPanel()
            } label: {
                Label("Open…", systemImage: "folder")
            }
            .keyboardShortcut(.defaultAction)

            if let welcome = Bundle.main.url(forResource: "Welcome", withExtension: "md") {
                Button {
                    openWindow(value: Optional(welcome))
                } label: {
                    Label("Read the Guide", systemImage: "book")
                }
            }
        }
        .controlSize(.large)
        .padding(.bottom, recents.entries.isEmpty ? 0 : 20)
    }

    // MARK: - Recents

    private var recentsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Recent")
                    .font(.system(size: 11, weight: .semibold).smallCaps())
                    .foregroundStyle(theme.textTertiary)
                Spacer()
                Button("Clear") { recents.clear() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
                    .help("Clear the recent files list")
            }
            .padding(.horizontal, 6)
            .padding(.top, 20)
            .padding(.bottom, 4)

            ForEach(recents.entries) { entry in
                RecentRow(entry: entry) { openWindow(value: Optional(entry.url)) }
            }
        }
    }

    // MARK: - Drop handling

    private func open(dropped urls: [URL]) -> Bool {
        guard let url = urls.first(where: { markdownExtensions.contains($0.pathExtension.lowercased()) }) else {
            return false
        }
        openWindow(value: Optional(url))
        return true
    }
}

/// One recent-file row: filename + abbreviated location, with a hover fill and
/// the whole row a single click/keyboard target.
private struct RecentRow: View {
    let entry: RecentDocumentsStore.Entry
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.accent)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(entry.location)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? theme.tableRowHoverFill : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(entry.url.path)
        .accessibilityLabel("\(entry.name), in \(entry.location)")
    }
}

private extension View {
    /// `.glassEffect` only when transparency is allowed; otherwise the caller's
    /// own opaque background stands in.
    @ViewBuilder
    func glassEffectIfAvailable(enabled: Bool) -> some View {
        if enabled {
            glassEffect(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            self
        }
    }
}
