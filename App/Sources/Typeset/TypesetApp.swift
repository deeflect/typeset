import SwiftUI

@main
struct TypesetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // App structs can read the environment inside `body`; this hands
        // SwiftUI's `openWindow` action to `DocumentOpener`, which is the one
        // place that decides whether a request needs a new window at all.
        let _ = DocumentOpener.shared.openWindowAction = { url in
            openWindow(value: Optional(url))
        }
        let _ = DocumentOpener.shared.openEmptyWindowAction = {
            openWindow(value: URL?.none)
        }

        WindowGroup(for: URL?.self) { $url in
            DocumentWindow(url: url)
        } defaultValue: {
            nil
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 880, height: 820)
        .windowResizability(.contentMinSize)
        // Scene restoration brought every window from the last session back
        // as an *empty* one: the restored `URL` values are stale outside the
        // sandbox scope that granted them, so a session that ended with three
        // windows opened three blank "Typeset" windows on every subsequent
        // launch, on top of whatever file was double-clicked. Recents (which
        // are security-scoped bookmarks, and do survive) are the supported
        // way back to a document.
        .restorationBehavior(.disabled)
        .commands {
            TypesetCommands(openPanel: { appDelegate.openPanel() })
        }
    }
}
