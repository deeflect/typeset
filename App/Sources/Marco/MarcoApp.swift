import SwiftUI

@main
struct MarcoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @AppStorage("textScale") private var textScale: Double = 1.0

    private let minScale = 0.8
    private let maxScale = 1.8
    private let scaleStep = 0.1

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
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    appDelegate.openPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Actual Size") { textScale = 1.0 }
                    .keyboardShortcut("0", modifiers: .command)
                Button("Zoom In") {
                    textScale = min(maxScale, (textScale + scaleStep).rounded(toPlaces: 2))
                }
                .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") {
                    textScale = max(minScale, (textScale - scaleStep).rounded(toPlaces: 2))
                }
                .keyboardShortcut("-", modifiers: .command)
                Divider()
            }
        }
    }
}

private extension Double {
    /// Rounds to a fixed number of decimals so accumulated ⌘+/⌘− steps
    /// don't drift into values like 1.2000000000000002.
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
