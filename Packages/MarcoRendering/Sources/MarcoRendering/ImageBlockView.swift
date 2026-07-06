import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Detects a paragraph that is nothing but a single image.
public enum InlineImage {
    public static func soleImage(in raw: String) -> (alt: String, source: String)? {
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
    @Environment(\.presentLightbox) private var presentLightbox

    @State private var image: NSImage?
    @State private var failure: LoadFailure?
    @State private var hovering = false

    /// Distinguishes a plain "unavailable" placeholder from one where the
    /// sandbox is the reason — the latter gets a quiet "Allow access"
    /// affordance instead of a dead end.
    private enum LoadFailure: Equatable {
        case unavailable
        case needsAccess(folder: URL)
    }

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
                    // Click to zoom in a Quick Look-style lightbox; drag the
                    // image out to Finder (local file) or into another app
                    // (any image) — PLAN §6.
                    .overlay(alignment: .topTrailing) { zoomHint(for: displayImage) }
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onHover { hovering = $0 }
                    .onTapGesture { presentLightbox?(displayImage) }
                    .onDrag { dragProvider(for: displayImage) }
                    .help(presentLightbox == nil ? "" : "Click to zoom")
                    .accessibilityElement()
                    .accessibilityLabel(alt.isEmpty ? "Image" : alt)
                    .accessibilityAddTraits(presentLightbox == nil ? .isImage : [.isImage, .isButton])
            } else if failure != nil || isSnapshot {
                placeholder
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.codeCardFill)
                    .frame(height: 120)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: source) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: FolderAccessStore.accessGrantedNotification)) { _ in
            // A folder was just granted (from this or any other broken
            // image's affordance) — quietly re-attempt in place.
            guard failure != nil else { return }
            Task { await load() }
        }
    }

    /// A quiet magnifier badge that fades in on hover, signalling the image
    /// is clickable to zoom. Suppressed when there's no lightbox to present
    /// (snapshot / Quick Look).
    @ViewBuilder
    private func zoomHint(for _: NSImage) -> some View {
        if presentLightbox != nil {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(6)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .padding(10)
                .opacity(hovering ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .allowsHitTesting(false)
        }
    }

    /// Drag payload: the on-disk file for a local image (so a drop in Finder
    /// copies the real file), otherwise the decoded image itself.
    private func dragProvider(for displayImage: NSImage) -> NSItemProvider {
        if let url = resolvedURL(), url.isFileURL,
           let provider = NSItemProvider(contentsOf: url) {
            return provider
        }
        return NSItemProvider(object: displayImage)
    }

    @ViewBuilder
    private var placeholder: some View {
        HStack(spacing: theme.scaled(12)) {
            Image(systemName: needsAccessFolder == nil ? "photo" : "lock.slash")
                .font(.system(size: 22))
                .foregroundStyle(theme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(placeholderTitle)
                    .font(theme.bodyFont)
                    .foregroundStyle(theme.textSecondary)
                Text(source)
                    .font(theme.monoFont(11))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if let folder = needsAccessFolder, !isSnapshot {
                Button("Allow Access\u{2026}") { requestAccess(to: folder) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(theme.scaled(16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.codeCardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.codeCardStroke, lineWidth: 1)
        )
    }

    private var needsAccessFolder: URL? {
        if case .needsAccess(let folder) = failure { return folder }
        return nil
    }

    private var placeholderTitle: String {
        if needsAccessFolder != nil {
            return alt.isEmpty ? "Image needs folder access" : alt
        }
        return alt.isEmpty ? "Image unavailable" : alt
    }

    private func requestAccess(to folder: URL) {
        FolderAccessStore.shared.requestAccess(
            defaultDirectory: folder,
            message: "Allow \(Bundle.main.displayName) to open images in \u{201c}\(folder.lastPathComponent)\u{201d}.")
        // The store posts `accessGrantedNotification` on success, which the
        // `.onReceive` above turns into an immediate reload; nothing else
        // to do here if the user cancels the panel.
    }

    private func load() async {
        image = nil
        failure = nil
        guard let url = resolvedURL() else { failure = .unavailable; return }
        let target = 1600
        let loaded = await Task.detached(priority: .utility) {
            ImageBlockView.downsampledImage(at: url, maxPixel: target)
        }.value
        if let loaded {
            image = loaded
        } else if url.isFileURL, !FolderAccessStore.shared.access(to: url), FolderAccessStore.isAccessDenied(at: url) {
            failure = .needsAccess(folder: url.deletingLastPathComponent())
        } else {
            failure = .unavailable
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

public extension EnvironmentValues {
    /// The URL of the document currently being rendered, used to resolve
    /// relative image and link paths.
    @Entry var documentBaseURL: URL? = nil

    /// True while rendering via `ImageRenderer` for a headless snapshot,
    /// where `ScrollView` content isn't captured — views substitute a
    /// non-scrolling layout.
    @Entry var isSnapshot: Bool = false
}
