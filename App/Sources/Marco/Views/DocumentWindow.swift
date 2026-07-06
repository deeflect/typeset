import MarcoCore
import SwiftUI

/// v0 window shell: proves the open-file plumbing and the parser, not
/// the real renderer (that's M1). Shows the raw text plus a parsed
/// block count so we can see `MarkdownParser` running end to end.
struct DocumentWindow: View {
    let url: URL?

    @State private var text: String = ""
    @State private var blocks: [Block] = []
    @State private var loadError: String?

    var body: some View {
        Group {
            if let url {
                content(for: url)
            } else {
                EmptyStateView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(url?.lastPathComponent ?? Bundle.main.displayName)
                    .font(.headline)
            }
        }
        .task(id: url) {
            guard let url else { return }
            load(from: url)
        }
    }

    @ViewBuilder
    private func content(for url: URL) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let loadError {
                Text(loadError)
                    .foregroundStyle(.red)
                    .padding()
            }

            HStack {
                Label("\(blocks.count) blocks parsed", systemImage: "square.stack.3d.up")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .glassEffect(in: RoundedRectangle(cornerRadius: 12))

            Divider()

            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }

    private func load(from url: URL) {
        do {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            let loaded = try String(contentsOf: url, encoding: .utf8)
            text = loaded
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
