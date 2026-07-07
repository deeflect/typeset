import AppKit
import MarcoCore
import MarcoRendering
import SwiftUI

// Debug-only: throwaway M6 Phase 0 spike (see TextKit2SpikeStyler.swift).
#if DEBUG

/// Builds one non-editable `NSTextView` explicitly constructed on TextKit 2
/// (`NSTextContentStorage` + `NSTextLayoutManager`), backed by `storage`
/// (raw Markdown source + attributes, built by `TextKit2SpikeStyler`).
/// Read-only per PLAN §0 scope — no typing, no editing wiring. A plain
/// factory (not a SwiftUI `NSViewRepresentable`) so the bench harness can
/// call it directly and keep the returned `Retained` bundle alive itself,
/// with no SwiftUI state-identity indirection in between.
@MainActor
enum TextKit2SpikeFactory {
    /// Owns the TextKit 2 stack's strong references: `NSTextLayoutManager`
    /// holds its `textContentManager` weakly, so something outside the
    /// TextKit graph itself has to keep `NSTextContentStorage` alive for
    /// the view's lifetime, or layout silently stops.
    final class Retained {
        var contentStorage: NSTextContentStorage?
        var layoutManager: NSTextLayoutManager?
        var fragmentDelegate: SpikeLayoutManagerDelegate?
        var textView: NSTextView?
    }

    static func makeScrollView(storage: NSTextStorage, containerWidth: CGFloat) -> (NSScrollView, Retained) {
        let contentStorage = NSTextContentStorage()
        contentStorage.textStorage = storage

        let layoutManager = NSTextLayoutManager()
        let fragmentDelegate = SpikeLayoutManagerDelegate()
        layoutManager.delegate = fragmentDelegate
        contentStorage.addTextLayoutManager(layoutManager)

        let container = NSTextContainer(size: CGSize(width: containerWidth, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.textContainer = container

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 24, height: 24)
        textView.drawsBackground = true

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.documentView = textView

        let retained = Retained()
        retained.contentStorage = contentStorage
        retained.layoutManager = layoutManager
        retained.fragmentDelegate = fragmentDelegate
        retained.textView = textView
        return (scrollView, retained)
    }
}

/// Comparison baseline: the *actual* shipping block renderer
/// (`MarcoRendering.BlockView`) inside a bare `ScrollView` + `LazyVStack`,
/// with none of `DocumentRenderer`'s window chrome (toolbar, copy HUD,
/// live-reload pulse wiring) — those don't touch the render/scroll hot
/// path, so this isolates exactly the cost PLAN §0 asks about while
/// reusing the real per-block view code (not a reimplementation).
struct SpikeLazyVStackView: View {
    let blocks: [Block]
    let documentURL: URL?
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(blocks) { block in
                    BlockView(block: block).id(block.id)
                }
            }
            .frame(maxWidth: theme.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, theme.contentHorizontalPadding)
            .padding(.top, theme.contentTopPadding)
            .padding(.bottom, theme.contentBottomPadding)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(theme.background)
        .environment(\.documentBaseURL, documentURL)
    }
}
#endif
