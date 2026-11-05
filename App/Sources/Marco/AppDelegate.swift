import AppKit
import UniformTypeIdentifiers
import MarcoRendering

/// Bridges AppKit-only entry points (Finder double-click / drag-to-Dock,
/// the classic `NSOpenPanel`, Dock reopen) into `DocumentOpener`, which
/// decides which window each request should land in.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            DocumentOpener.shared.prepareToTerminate() ? .terminateNow : .terminateCancel
        }
    }
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
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { DocumentOpener.shared.open(urls) }
    }

    /// No. SwiftUI's `WindowGroup` already creates its default (empty-state)
    /// window at launch; answering `true` here made AppKit ask for a *second*
    /// one, which is one of the stray empty windows a Finder open used to
    /// leave behind. Reopen from the Dock is handled below instead.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    /// Always `false` — every reopen is handled here, never by AppKit.
    ///
    /// Letting AppKit do its default reopen handling spawned a fresh empty
    /// window each time the app was activated with a file (`open -a Marco
    /// foo.md` on an already-running app), which is the second half of the
    /// "opening one file gives me three windows" bug. Reopen with no windows
    /// left is the one case that legitimately wants a window; `DocumentOpener`
    /// supplies the empty-state one, and a file arriving right behind it will
    /// land in that same window rather than a new one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return false }
        MainActor.assumeIsolated { DocumentOpener.shared.openEmptyWindow() }
        return false
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
        DocumentOpener.shared.open(panel.urls)
    }
}
