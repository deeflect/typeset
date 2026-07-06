import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Detects a paragraph that is nothing but a single image.
enum InlineImage {
    static func soleImage(in raw: String) -> (alt: String, source: String)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("!["), text.hasSuffix(")"),
              let altEnd = text.firstIndex(of: "]"),
              text.index(after: altEnd) < text.endIndex,
              text[text.index(after: altEnd)] == "(" else { return nil }
        let alt = String(text[text.index(text.startIndex, offsetBy: 2)..<altEnd])
        let srcStart = text.index(altEnd, offsetBy: 2)
        var source = String(text[srcStart..<text.index(before: text.endIndex)])
        // Drop an optional title: ![alt](src "title")
        if let space = source.firstIndex(of: " ") { source = String(source[..<space]) }
        source = source.trimmingCharacters(in: .whitespaces)
        // Reject if the alt/source span wasn't the whole paragraph (e.g. inline image mid-text).
        guard !source.isEmpty, !source.contains("![") else { return nil }
        return (alt, source)
    }
}

/// Renders an image: remote URLs via async load, local relative paths
/// resolved against the document's directory. Downsampled decode, rounded
/// corners, capped to the column width. Falls back to a graceful
/// placeholder when the file can't be read (e.g. parent-dir assets under
/// the sandbox).
struct ImageBlockView: View {
    let alt: String
    let source: String
    @Environment(\.theme) private var theme
    @Environment(\.documentBaseURL) private var baseURL
    @Environment(\.isSnapshot) private var isSnapshot

    @State private var image: NSImage?
    @State private var failed = false

    /// In snapshots the async `.task` never completes, so resolve the image
    /// synchronously (it's a one-shot render).
    private var displayImage: NSImage? {
        if let image { return image }
        if isSnapshot, let url = resolvedURL() {
            return ImageBlockView.downsampledImage(at: url, maxPixel: 1600)
        }
        return nil
    }

    var body: some View {
        Group {
            if let displayImage {
                Image(nsImage: displayImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(theme.codeCardStroke, lineWidth: 1)
                    )
            } else if failed || isSnapshot {
                placeholder
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.codeCardFill)
                    .frame(height: 120)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: source) { await load() }
    }

    private var placeholder: some View {
        HStack(spacing: theme.scaled(12)) {
            Image(systemName: "photo")
                .font(.system(size: 22))
                .foregroundStyle(theme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(alt.isEmpty ? "Image unavailable" : alt)
                    .font(theme.bodyFont)
                    .foregroundStyle(theme.textSecondary)
                Text(source)
                    .font(theme.monoFont(11))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(theme.scaled(16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.codeCardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.codeCardStroke, lineWidth: 1)
        )
    }

    private func load() async {
        image = nil
        failed = false
        guard let url = resolvedURL() else { failed = true; return }
        let target = 1600
        let loaded = await Task.detached(priority: .utility) {
            ImageBlockView.downsampledImage(at: url, maxPixel: target)
        }.value
        if let loaded {
            image = loaded
        } else {
            failed = true
        }
    }

    private func resolvedURL() -> URL? {
        if source.hasPrefix("http://") || source.hasPrefix("https://") {
            return URL(string: source)
        }
        if source.hasPrefix("file://") { return URL(string: source) }
        guard let baseURL else { return nil }
        let directory = baseURL.deletingLastPathComponent()
        return directory.appendingPathComponent(source).standardizedFileURL
    }

    /// ImageIO thumbnail decode — never fully decodes huge originals.
    nonisolated static func downsampledImage(at url: URL, maxPixel: Int) -> NSImage? {
        let isRemote = url.scheme == "http" || url.scheme == "https"
        var didAccess = false
        if !isRemote { didAccess = url.startAccessingSecurityScopedResource() }
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

extension EnvironmentValues {
    /// The URL of the document currently being rendered, used to resolve
    /// relative image and link paths.
    @Entry var documentBaseURL: URL? = nil

    /// True while rendering via `ImageRenderer` for a headless snapshot,
    /// where `ScrollView` content isn't captured — views substitute a
    /// non-scrolling layout.
    @Entry var isSnapshot: Bool = false
}
