import AppKit
import UniformTypeIdentifiers
import MarcoRendering

/// Bridges AppKit-only entry points (Finder double-click / drag-to-Dock,
/// and the classic `NSOpenPanel`) into SwiftUI's `openWindow` action.
///
/// `MarcoApp` wires `onOpenURLs` once it has access to `openWindow` from
/// the environment (App structs can read `@Environment` in `body`).
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onOpenURLs: (([URL]) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Resolves + starts accessing every persisted folder-access
        // bookmark (see FolderAccessStore) and logs the active grants.
        _ = FolderAccessStore.shared
        // Headless bench/snapshot entry points (env-var triggered) never
        // ship in Release: the runner types themselves are `#if DEBUG`-gated
        // (PLAN §8), so a Release binary has no code path that reads
        // MARCO_SNAPSHOT/MARCO_*_BENCH — setting them is a guaranteed no-op.
        #if DEBUG
        // Headless snapshot mode (visual verification without Screen
        // Recording): render the requested file to PNGs and exit.
        if SnapshotRunner.runIfRequested() {
            NSApp.terminate(nil)
            return
        }
        // Headless live-reload verification (visible watcher/reload
        // pipeline exercise without a window): watches the requested file
        // and reports each applied reload's latency, then exits.
        if ReloadBenchRunner.runIfRequested() {
            return
        }
        // Headless M3 verification (checkbox write-back, save, conflict
        // banner) without a visible window.
        if EditBenchRunner.runIfRequested() {
            return
        }
        if StyleBenchRunner.runIfRequested() {
            return
        }
        // Headless ⌘F perf verification (segment build / search / highlight
        // apply on a large file) without a visible window.
        if FindBenchRunner.runIfRequested() {
            NSApp.terminate(nil)
            return
        }
        #endif
        // Suppress the automatic "Untitled" window macOS would otherwise
        // create for a document-based-looking app with no file yet — we
        // want the empty-state window instead, which WindowGroup(for:)
        // already supplies via its `defaultValue`.
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        onOpenURLs?(urls)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    @MainActor
    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["md", "markdown", "mdown"].compactMap {
            UTType(filenameExtension: $0)
        }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        onOpenURLs?(panel.urls)
    }
}
