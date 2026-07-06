import AppKit
import SwiftUI

/// Environment plumbing shared by the block renderer, relocated here (out of
/// the app target) so the same rendering surface can be reused unmodified by
/// the Quick Look extension. Every key defaults to an inert value (`nil` /
/// `false`), which is exactly the Quick Look/snapshot posture: read-only,
/// non-interactive rendering with no watcher and no editing.
public extension EnvironmentValues {
    /// Reading-view images call this to open the full-window lightbox. `nil`
    /// (snapshot / Quick Look) leaves images non-interactive.
    @Entry var presentLightbox: ((NSImage) -> Void)? = nil
}
