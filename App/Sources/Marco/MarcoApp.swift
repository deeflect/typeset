import SwiftUI

@main
struct MarcoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // App structs can read the environment inside `body`; this wires
        // AppKit's Finder-open / open-panel callback to SwiftUI's
        // `openWindow` action once it's available.
        let _ = appDelegate.onOpenURLs = { urls in
            for url in urls {
                openWindow(value: Optional(url))
            }
        }

        WindowGroup(for: URL?.self) { $url in
            DocumentWindow(url: url)
        } defaultValue: {
            nil
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    appDelegate.openPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
