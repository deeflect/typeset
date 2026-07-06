import SwiftUI

/// Environment plumbing for PLAN §5's reading-view checkbox write-back:
/// task-list checkboxes are interactive without entering edit mode. Kept
/// separate from `ImageBlockView`'s environment keys since this is purely
/// an M3 editing concern.
extension EnvironmentValues {
    /// The `Block.startLine` of the top-level list/blockquote block
    /// currently being rendered, so a `ListView` nested arbitrarily deep
    /// inside `StructuredChildView` recursion (a quote containing a list
    /// containing a list, etc.) can resolve an absolute checkbox line
    /// without threading it through every intermediate view's parameters.
    /// Set once per top-level block by `BlockView`. `-1` means "not inside
    /// a block that owns a real line range" (checkbox taps are ignored).
    @Entry var checkboxBlockStartLine: Int = -1

    /// Reading-view checkbox write-back (PLAN §5): called with the owning
    /// block's `startLine`, the item's `checkboxLineOffset`, and the new
    /// target checked state when a task checkbox is clicked. `nil` (the
    /// default) renders checkboxes as static, non-interactive glyphs — used
    /// by the snapshot/QuickLook paths, which have no writable document.
    @Entry var checkboxToggleHandler: ((Int, Int, Bool) -> Void)? = nil
}
