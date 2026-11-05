import AppKit
import MarcoCore
import MarcoRendering
import SwiftUI

#if DEBUG
/// Headless captures of the shipping native reader.
/// MARCO_SNAPSHOT=file.md MARCO_SNAPSHOT_OUT=dir MARCO_SNAPSHOT_WIDTH=540
@MainActor
enum SnapshotRunner {
    static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["MARCO_SNAPSHOT"] else { return false }
        let url = URL(fileURLWithPath: path)
        let output = env["MARCO_SNAPSHOT_OUT"] ?? FileManager.default.currentDirectoryPath
        let width = max(400, env["MARCO_SNAPSHOT_WIDTH"].flatMap(Double.init) ?? 760)
        let scale = env["MARCO_SNAPSHOT_SCALE"].flatMap(Double.init) ?? 1
        let variant = env["MARCO_SNAPSHOT_VARIANT"] ?? "reading"
        let basename = url.deletingPathExtension().lastPathComponent
        Task {
            defer { NSApp.terminate(nil) }
            guard variant == "reading" || variant == "empty" else {
                FileHandle.standardError.write(Data("snapshot: unsupported variant \(variant)\n".utf8))
                return
            }
            if variant == "empty" {
                RecentDocumentsStore.shared.seedForSnapshot([url])
                let renderer = ImageRenderer(content: EmptyStateView().frame(width: width, height: 460))
                renderer.scale = 2
                if let image = renderer.cgImage { write(image, to: "\(output)/\(basename)-empty.png") }
                return
            }
            do {
                let readStart = DispatchTime.now()
                let source = try await Task.detached(priority: .userInitiated) {
                    try String(contentsOf: url, encoding: .utf8)
                }.value
                let readMs = milliseconds(since: readStart)
                for scheme in [ColorScheme.light, .dark] {
                    let theme = Theme(colorScheme: scheme, scale: CGFloat(scale))
                    let buildStart = DispatchTime.now()
                    let snapshot = await Task.detached(priority: .userInitiated) {
                        NativeMarkdownDocument.build(source: source, blocks: MarkdownParser.parse(source), theme: theme, documentURL: url)
                    }.value
                    let buildMs = milliseconds(since: buildStart)
                    let layoutStart = DispatchTime.now()
                    let reader = NativeMarkdownReadingView(document: snapshot, theme: theme, controller: .init())
                    let hosting = NSHostingView(rootView: reader)
                    hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    hosting.frame = NSRect(x: 0, y: 0, width: width, height: 900)
                    hosting.layoutSubtreeIfNeeded()
                    let layoutMs = milliseconds(since: layoutStart)
                    let rasterStart = DispatchTime.now()
                    if let first = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                        hosting.cacheDisplay(in: hosting.bounds, to: first)
                    }
                    let firstRasterMs = milliseconds(since: rasterStart)
                    FileHandle.standardError.write(Data(
                        "snapshot: \(scheme == .dark ? "dark" : "light") readMs=\(readMs) buildMs=\(buildMs) layoutMs=\(layoutMs) firstRasterMs=\(firstRasterMs)\n".utf8))
                    try? await Task.sleep(for: .milliseconds(250))
                    let suffix = scheme == .dark ? "dark" : "light"
                    let name = variant == "reading" ? "\(basename)-\(suffix)" : "\(basename)-\(variant)-\(suffix)"
                    if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                        hosting.cacheDisplay(in: hosting.bounds, to: rep)
                        if let data = rep.representation(using: .png, properties: [:]) {
                            try data.write(to: URL(fileURLWithPath: "\(output)/\(name).png"))
                            FileHandle.standardError.write(Data("snapshot: wrote \(output)/\(name).png\n".utf8))
                        }
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8))
            }
        }
        return true
    }

    private static func write(_ image: CGImage, to path: String) {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    private static func milliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }
}
#endif
