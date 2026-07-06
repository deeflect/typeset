import AppKit
import UniformTypeIdentifiers

/// Bridges AppKit-only entry points (Finder double-click / drag-to-Dock,
/// and the classic `NSOpenPanel`) into SwiftUI's `openWindow` action.
///
/// `MarcoApp` wires `onOpenURLs` once it has access to `openWindow` from
/// the environment (App structs can read `@Environment` in `body`).
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onOpenURLs: (([URL]) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
