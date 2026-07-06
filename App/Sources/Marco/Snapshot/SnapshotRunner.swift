import AppKit
import MarcoCore
import SwiftUI

/// Headless snapshot path: renders a Markdown file to PNGs (light + dark)
/// with `ImageRenderer`, entirely in-process, so the reading view can be
/// verified visually without Screen Recording permission. Triggered by the
/// `MARCO_SNAPSHOT` environment variable; the app renders and exits.
///
///   MARCO_SNAPSHOT=/path/to/file.md
///   MARCO_SNAPSHOT_OUT=/path/to/output/dir   (optional)
///   MARCO_SNAPSHOT_SCALE=1.0                  (optional text-size scale)
@MainActor
enum SnapshotRunner {
    static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let filePath = env["MARCO_SNAPSHOT"] else { return false }

        let outDir = env["MARCO_SNAPSHOT_OUT"] ?? FileManager.default.currentDirectoryPath
        let scale = env["MARCO_SNAPSHOT_SCALE"].flatMap { Double($0) } ?? 1.0
        let url = URL(fileURLWithPath: filePath)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "# Could not read file\n\n`\(filePath)`"
        let blocks = MarkdownParser.parse(text)
        let base = url.deletingPathExtension().lastPathComponent
        FileHandle.standardError.write(Data("snapshot: parsed \(blocks.count) blocks from \(base)\n".utf8))

        for scheme in [ColorScheme.light, ColorScheme.dark] {
            // Pre-warm syntax highlighting so code cards render colored
            // (ImageRenderer can't await the async .task path).
            for block in blocks {
                if case .codeBlock(let language) = block.kind {
                    CodeHighlighter.shared.warm(
                        code: CodeBlockView.extractCode(block.rawText),
                        language: language, isDark: scheme == .dark)
                }
            }

            let theme = Theme(colorScheme: scheme, scale: CGFloat(scale))
            let column = SnapshotColumn(blocks: blocks, documentURL: url)
                .environment(\.theme, theme)
                .environment(\.colorScheme, scheme)

            let renderer = ImageRenderer(content: column)
            renderer.scale = 2
            renderer.isOpaque = true

            let suffix = scheme == .dark ? "dark" : "light"
            let path = "\(outDir)/\(base)-\(suffix).png"
            if let cgImage = renderer.cgImage {
                writePNG(cgImage, to: path)
                FileHandle.standardError.write(Data("snapshot: wrote \(path)\n".utf8))
            } else {
                FileHandle.standardError.write(Data("snapshot: FAILED to render \(path)\n".utf8))
            }
        }
        return true
    }

    private static func writePNG(_ cgImage: CGImage, to path: String) {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot: PNG encode failed\n".utf8))
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("snapshot: write failed \(error)\n".utf8))
        }
    }
}

/// A non-scrolling copy of the reading column, sized so `ImageRenderer`
/// captures the full document height.
private struct SnapshotColumn: View {
    let blocks: [Block]
    let documentURL: URL?
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
        .environment(\.isSnapshot, true)
    }
}
