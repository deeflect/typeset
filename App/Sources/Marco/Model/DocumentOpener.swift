import AppKit
import SwiftUI

/// The single funnel every "open this file" request goes through — Finder
/// double-click, the Open panel, the empty-state recents list, and drag-drop.
///
/// Before this existed each entry point called `openWindow(value:)` directly
/// and nothing reconciled the result against the windows already on screen,
/// which produced the "one file opens three windows" bug. Three separate
/// things were making windows:
///
/// 1. **Scene restoration** brought back every window from the last session,
///    blank (fixed in `MarcoApp` with `.restorationBehavior(.disabled)`).
/// 2. **`applicationShouldOpenUntitledFile`** answered `true`, asking for one
///    more (fixed in `AppDelegate`).
/// 3. **The system itself** creates a fresh `WindowGroup` default window for
///    every open/activate event, before the delegate callback even fires.
///
/// (3) can't be suppressed, so this type absorbs it instead: a request either
/// lands in that window, or — when the file is already open somewhere and the
/// window is surplus — closes it again. Everything routes through `open`, so
/// there is exactly one place that decides whether a window is needed.
@MainActor
final class DocumentOpener {
    static let shared = DocumentOpener()
    private init() {}

    /// Bridged in by `MarcoApp`, which is the only place SwiftUI's
    /// `openWindow` action is reachable.
    var openWindowAction: ((URL) -> Void)?
    /// Same, for a window with no document (the empty-state home screen).
    var openEmptyWindowAction: (() -> Void)?

    /// Live document windows, weakly held, in registration order.
    private var models: [Entry] = []
    /// URLs waiting for a window to land in (see `drain`).
    private var pending: [URL] = []
    private var drainScheduled = false
    private var waited: TimeInterval = 0

    /// How long `drain` waits for the system's window to materialise before
    /// opening one itself. Only ever elapses if that window never arrives.
    private static let windowTimeout: TimeInterval = 1.0
    private static let drainInterval: TimeInterval = 0.02
    /// A document-less window that registered this recently was conjured by
    /// the open event we are servicing, not opened by the user — so it is
    /// ours to close if the request didn't need it.
    private static let systemWindowGrace: TimeInterval = 2.0

    // MARK: - Window registry

    func register(_ model: WindowModel) {
        prune()
        guard !models.contains(where: { $0.model === model }) else { return }
        models.append(Entry(model: model, registered: Date()))
    }

    func unregister(_ model: WindowModel) {
        models.removeAll { $0.model == nil || $0.model === model }
    }

    private func prune() { models.removeAll { $0.model == nil } }

    /// The model driving `window`, for AppKit-side code (responder-chain
    /// actions, menu validation) that only has an `NSWindow` in hand.
    func model(for window: NSWindow?) -> WindowModel? {
        guard let window else { return nil }
        return liveModels.first { $0.window === window }
    }

    private var liveModels: [WindowModel] { models.compactMap(\.model) }

    func prepareToTerminate() -> Bool {
        realModels.allSatisfy { $0.prepareToClose() }
    }

    /// Windows that actually exist on screen. SwiftUI builds and discards
    /// transient `WindowModel`s while resolving a scene, and those never get
    /// an `NSWindow` — handing one a document would drop it on the floor.
    private var realModels: [WindowModel] { liveModels.filter { $0.window != nil } }

    // MARK: - Opening

    func open(_ urls: [URL]) {
        let wanted = urls.map(\.standardizedFileURL)
        guard !wanted.isEmpty else { return }
        pending.append(contentsOf: wanted)
        scheduleDrain()
    }

    func open(_ url: URL) { open([url]) }

    /// File ▸ New from Clipboard (Preview's ⌘N): writes the pasteboard's plain
    /// text to "Clipboard <date> at <time>.md" in the container's temporary
    /// folder and opens it like any file. Beeps when there's no text.
    func openClipboard(_ pasteboard: NSPasteboard = .general) {
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm"
        let base = "Clipboard \(formatter.string(from: Date()))"
        let folder = FileManager.default.temporaryDirectory
        var url = folder.appendingPathComponent(base + ".md")
        var copy = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(copy).md")
            copy += 1
        }
        do {
            try Data(text.utf8).write(to: url, options: .withoutOverwriting)
            open(url)
        } catch {
            NSSound.beep()
        }
    }

    /// Dock reopen with no windows left: bring the home screen back, or focus
    /// an empty-state window that is merely hidden.
    func openEmptyWindow() {
        if let idle = idleWindow() {
            focus(idle)
            return
        }
        openEmptyWindowAction?()
    }

    private func scheduleDrain() {
        guard !drainScheduled else { return }
        drainScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.drainInterval) { [weak self] in
            self?.drain()
        }
    }

    private func drain() {
        drainScheduled = false
        prune()
        guard !pending.isEmpty else { waited = 0; return }

        // The open event beats the window the system makes for it. Wait for
        // that window instead of racing it — losing the race is what left a
        // blank window beside every document.
        if realModels.isEmpty, waited < Self.windowTimeout {
            waited += Self.drainInterval
            scheduleDrain()
            return
        }
        waited = 0

        let urls = pending
        pending.removeAll()
        for url in urls { route(url) }
        closeSurplusSystemWindows()
    }

    private func route(_ url: URL) {
        if let existing = liveModels.first(where: { $0.currentURL?.standardizedFileURL == url }) {
            focus(existing)
            return
        }
        if let idle = idleWindow() {
            idle.load(initial: url)
            focus(idle)
            return
        }
        openWindowAction?(url)
    }

    /// A window with no document in it. Prefers the frontmost one so opening a
    /// file fills the window the user is actually looking at.
    private func idleWindow() -> WindowModel? {
        let idle = realModels.filter { $0.currentURL == nil }
        return idle.first(where: { $0.window?.isKeyWindow == true })
            ?? idle.first(where: { $0.window?.isMainWindow == true })
            ?? idle.first
    }

    /// Disposes of the window the system opened for a request that turned out
    /// not to need one — re-opening an already-open file, say. Scoped by time
    /// so a home-screen window the user deliberately has open is never touched.
    private func closeSurplusSystemWindows() {
        let cutoff = Date().addingTimeInterval(-Self.systemWindowGrace)
        for entry in models where entry.registered >= cutoff {
            guard let model = entry.model, model.currentURL == nil, let window = model.window else { continue }
            window.close()
        }
        prune()
    }

    private func focus(_ model: WindowModel) {
        NSApp.activate(ignoringOtherApps: false)
        model.window?.makeKeyAndOrderFront(nil)
    }

    private struct Entry {
        weak var model: WindowModel?
        let registered: Date
    }
}
