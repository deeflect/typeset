import AppKit
import MarcoCore
import SwiftUI
import MarcoRendering

// Debug-only: this diagnostic entry point never ships in Release (PLAN §8).
#if DEBUG

/// Headless snapshot path: renders a Markdown file to PNGs (light + dark)
/// with `ImageRenderer`, entirely in-process, so the reading view can be
/// verified visually without Screen Recording permission. Triggered by the
/// `MARCO_SNAPSHOT` environment variable; the app renders and exits.
///
///   MARCO_SNAPSHOT=/path/to/file.md
///   MARCO_SNAPSHOT_OUT=/path/to/output/dir       (optional)
///   MARCO_SNAPSHOT_SCALE=1.0                      (optional text-size scale)
///   MARCO_SNAPSHOT_VARIANT=reading|find           (optional, default reading)
///   MARCO_SNAPSHOT_FIND=needle                    (find variant query)
///
/// The `find` variant composes a static stand-in for the ⌘F bar (which
/// `ImageRenderer` can't host live), so the J3 feature is visually
/// verifiable in CI. The floating-glass material and live scroll tracking
/// it uses in the running app can't rasterize headlessly — those need
/// interactive eyes. (The outline dropdown is a transient native menu with
/// no headless-snapshot path.)
@MainActor
enum SnapshotRunner {
    static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let filePath = env["MARCO_SNAPSHOT"] else { return false }

        let outDir = env["MARCO_SNAPSHOT_OUT"] ?? FileManager.default.currentDirectoryPath
        let scale = env["MARCO_SNAPSHOT_SCALE"].flatMap { Double($0) } ?? 1.0
        let variant = env["MARCO_SNAPSHOT_VARIANT"] ?? "reading"
        let findQuery = env["MARCO_SNAPSHOT_FIND"] ?? ""
        let url = URL(fileURLWithPath: filePath)

        #if DEBUG
        // The empty-state home screen has no document — seed a few recents so
        // the list renders, and capture the opaque (Reduce Transparency)
        // surface since ImageRenderer can't rasterize the live glass backdrop.
        if variant == "empty" {
            RecentDocumentsStore.shared.seedForSnapshot([
                url,
                url.deletingLastPathComponent().appendingPathComponent("CLAUDE.md"),
                url.deletingLastPathComponent().appendingPathComponent("docs/architecture.md")
            ])
        }
        #endif
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "# Could not read file\n\n`\(filePath)`"
        let blocks = MarkdownParser.parse(text)
        let base = url.deletingPathExtension().lastPathComponent
        FileHandle.standardError.write(Data("snapshot: parsed \(blocks.count) blocks from \(base) (variant=\(variant))\n".utf8))

        for scheme in [ColorScheme.light, ColorScheme.dark] {
            prewarmCode(blocks: blocks, isDark: scheme == .dark)
            let theme = Theme(colorScheme: scheme, scale: CGFloat(scale))

            let root = rootView(variant: variant, blocks: blocks, url: url, theme: theme, findQuery: findQuery)
                .environment(\.theme, theme)
                .environment(\.colorScheme, scheme)

            let renderer = ImageRenderer(content: root)
            renderer.scale = 2
            renderer.isOpaque = true

            let suffix = scheme == .dark ? "dark" : "light"
            let name = variant == "reading" ? "\(base)-\(suffix)" : "\(base)-\(variant)-\(suffix)"
            let path = "\(outDir)/\(name).png"
            if let cgImage = renderer.cgImage {
                if writePNG(cgImage, to: path) {
                    FileHandle.standardError.write(Data("snapshot: wrote \(path)\n".utf8))
                }
            } else {
                FileHandle.standardError.write(Data("snapshot: FAILED to render \(path)\n".utf8))
            }
        }
        return true
    }

    @ViewBuilder
    private static func rootView(variant: String, blocks: [Block], url: URL, theme: Theme, findQuery: String) -> some View {
        switch variant {
        case "find":
            SnapshotFindScene(blocks: blocks, documentURL: url, query: findQuery)
        case "empty":
            EmptyStateView(forceOpaque: true)
                .frame(width: 760, height: 640)
        default:
            SnapshotColumn(blocks: blocks, documentURL: url)
        }
    }

    private static func prewarmCode(blocks: [Block], isDark: Bool) {
        for block in blocks {
            if case .codeBlock(let language) = block.kind {
                CodeHighlighter.shared.warm(
                    code: CodeBlockView.extractCode(block.rawText), language: language, isDark: isDark)
            }
        }
    }

    @discardableResult
    private static func writePNG(_ cgImage: CGImage, to path: String) -> Bool {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot: PNG encode failed\n".utf8))
            return false
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            FileHandle.standardError.write(Data("snapshot: write failed \(error)\n".utf8))
            return false
        }
    }
}

/// A non-scrolling copy of the reading column, sized so `ImageRenderer`
/// captures the full document height.
private struct SnapshotColumn: View {
    let blocks: [Block]
    let documentURL: URL?
    /// Optional ⌘F highlight to bake into the render (find variant).
    var findHighlight: FindHighlightContext? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                BlockView(block: block)
            }
        }
        .frame(maxWidth: theme.contentMaxWidth, alignment: .leading)
        .padding(.horizontal, theme.contentHorizontalPadding)
        .padding(.top, theme.contentTopPadding)
        .padding(.bottom, theme.scaled(56))
        .frame(width: theme.contentMaxWidth + theme.contentHorizontalPadding * 2, alignment: .center)
        .background(theme.background)
        .environment(\.documentBaseURL, documentURL)
        .environment(\.findHighlight, findHighlight)
        .environment(\.isSnapshot, true)
    }
}

/// Static stand-in for the ⌘F find bar above the reading column, with the
/// query's matches baked in (all tinted, the first one as the current match).
private struct SnapshotFindScene: View {
    let blocks: [Block]
    let documentURL: URL?
    let query: String
    @Environment(\.theme) private var theme

    private var context: (highlight: FindHighlightContext, status: String) {
        let (keys, texts) = FindSegmentBuilder.build(from: blocks)
        let matches = FindEngine.search(query: query, in: texts)
        let first = matches.first
        let currentKey = first.map { keys[$0.segmentIndex] }
        let highlight = FindHighlightContext(
            query: query, caseSensitive: false, currentKey: currentKey, currentStart: first?.start)
        let status = matches.isEmpty ? "No results" : "1 of \(matches.count)"
        return (highlight, status)
    }

    var body: some View {
        let ctx = context
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text(query).font(.system(size: 13))
                Spacer()
                Text(ctx.status).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                Image(systemName: "chevron.up").foregroundStyle(.secondary)
                Image(systemName: "chevron.down").foregroundStyle(.secondary)
                Image(systemName: "xmark").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(width: theme.contentMaxWidth + theme.contentHorizontalPadding * 2, alignment: .trailing)
            .background(theme.colorScheme == .dark ? Color(white: 0.16) : Color(white: 0.94))

            SnapshotColumn(blocks: blocks, documentURL: documentURL, findHighlight: ctx.highlight)
        }
    }
}
#endif
