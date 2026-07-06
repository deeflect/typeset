import AppKit
import SwiftUI

/// Grabs the hosting `NSWindow` once it's available, so SwiftUI state
/// (here, `DocumentReloadController.window`) can drive `isDocumentEdited`
/// for the standard title-bar/close-button dirty dot. A transparent,
/// zero-size `NSView` is the standard trick for this in a pure-SwiftUI
/// window (no `NSViewControllerRepresentable` document architecture here).
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
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
