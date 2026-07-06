import MarcoCore
import SwiftUI

/// The reading window: parses the opened file into `[Block]` and hands it to
/// the block renderer. Owns the app-wide text-size scale and derives the
/// `Theme` from the current appearance.
struct DocumentWindow: View {
    let url: URL?

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("textScale") private var textScale: Double = 1.0

    @State private var blocks: [Block] = []
    @State private var loadError: String?

    private var theme: Theme {
        Theme(colorScheme: colorScheme, scale: CGFloat(textScale))
    }

    var body: some View {
        Group {
            if let url {
                if let loadError {
                    errorView(loadError)
                } else {
                    DocumentRenderer(blocks: blocks, documentURL: url)
                }
            } else {
                EmptyStateView()
            }
        }
        .environment(\.theme, theme)
        .animation(.easeInOut(duration: 0.22), value: textScale)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(url?.lastPathComponent ?? Bundle.main.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .task(id: url) {
            guard let url else { return }
            load(from: url)
        }
        .onChange(of: colorScheme) { _, _ in
            InlineMarkdown.invalidate()
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }

    private func load(from url: URL) {
        do {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            let loaded = try String(contentsOf: url, encoding: .utf8)
            blocks = MarkdownParser.parse(loaded)
            loadError = nil
        } catch {
            loadError = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

extension Bundle {
    /// Never hardcode the app name in UI strings — read it from the
    /// bundle so renaming stays a single xcconfig edit.
    var displayName: String {
        (object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Untitled"
    }
}
