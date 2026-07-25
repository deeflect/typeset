import AppKit
import SwiftUI

/// Grabs the hosting `NSWindow` once it's available, so SwiftUI state
/// (here, `DocumentReloadController.window`) can drive `isDocumentEdited`
/// for the standard title-bar/close-button dirty dot. A transparent,
/// zero-size `NSView` is the standard trick for this in a pure-SwiftUI
/// window (no `NSViewControllerRepresentable` document architecture here).
///
/// Resolution hangs off `viewDidMoveToWindow` rather than a `DispatchQueue`
/// hop out of `makeNSView`/`updateNSView`. The old version reported whatever
/// `view.window` happened to be a runloop turn later, which is `nil` while
/// SwiftUI is re-parenting the view — so a perfectly good window reference
/// got overwritten with `nil` shortly after the window appeared, silently
/// disconnecting the window title, the dirty dot and live-resize tracking.
/// Only real windows are reported; teardown is `onDisappear`'s job.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ResolvingView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ResolvingView else { return }
        view.onResolve = onResolve
        if let window = view.window { onResolve(window) }
    }

    final class ResolvingView: NSView {
        var onResolve: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            onResolve?(window)
        }
    }
}

/// Captures the backing `NSView` of the view it's placed behind, so a native
/// `NSMenu` (the outline dropdown) can pop up anchored to the toolbar button
/// — both on click and when ⌘1 triggers it with no mouse location in hand.
struct OutlineAnchorAccessor: NSViewRepresentable {
    let onResolve: (NSView?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onResolve(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView) }
    }
}
