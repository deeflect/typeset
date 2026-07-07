import AppKit
import MarcoCore
import MarcoRendering
import SwiftUI

// Debug-only headless renderer for the M6 TextKit 2 reading surface. Builds the
// real styled `NSTextStorage`, lays it out in a windowless TextKit 2 stack, and
// draws the fragments straight into a bitmap — no window, no runloop, so it
// can't hang the way an off-window `cacheDisplay` can, and it exercises the
// real `MarcoReadingLayoutFragment.draw`. Reached via `SnapshotRunner`'s
// `MARCO_SNAPSHOT_VARIANT=textkit` (the proven headless launch/terminate
// path). Never reachable in Release (this whole file is `#if DEBUG`).
#if DEBUG
@MainActor
enum TextKitReadingSnapshotRunner {
    /// Renders one (scheme) PNG of the reading surface for `text`/`blocks`.
    static func writePNG(text: String, blocks: [Block], theme: Theme, baseURL: URL?, to path: String) {
        let width = MarcoReadingMetrics.contentMaxWidth + MarcoReadingMetrics.contentHorizontalPadding * 2
        let sidePad = MarcoReadingMetrics.contentHorizontalPadding
        let topPad = MarcoReadingMetrics.contentTopPadding

        let appearance = NSAppearance(named: theme.colorScheme == .dark ? .darkAqua : .aqua)!
        NSAppearance.current = appearance

        let contentStorage = NSTextContentStorage()
        let storage = NSTextStorage()
        contentStorage.textStorage = storage
        let layoutManager = NSTextLayoutManager()
        let delegate = MarcoReadingLayoutManagerDelegate(palette: ReadingDecorationPalette(theme: theme))
        delegate.backingScale = 2
        layoutManager.delegate = delegate
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: MarcoReadingMetrics.contentMaxWidth, height: 1_000_000))
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container

        let t0 = Date()
        let built = TextKitReadingStyler.build(text: text, blocks: blocks, theme: theme, baseURL: baseURL)
        storage.setAttributedString(built.storage)
        let styleMs = Date().timeIntervalSince(t0) * 1000
        layoutManager.ensureLayout(for: contentStorage.documentRange)
        let usage = layoutManager.usageBoundsForTextContainer
        let height = ceil(usage.height) + topPad * 2
        FileHandle.standardError.write(Data("tk-snapshot: style(+image-measure)=\(String(format: "%.1f", styleMs))ms\n".utf8))

        FileHandle.standardError.write(Data("tk-snapshot: container=\(container.size.width) usage=\(usage.width)x\(usage.height)\n".utf8))
        let px = Int(width * 2), pyh = max(1, Int(height * 2))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: pyh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        // Set the point size BEFORE creating the context so its CTM is the
        // intended 2x (otherwise drawing lands at 1x in a 2x-pixel canvas).
        rep.size = NSSize(width: width, height: height)
        guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        let ctx = nsCtx.cgContext

        NSColor(theme.background).setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Flip into TextKit's y-down space, then offset by the reading insets.
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: sidePad, y: topPad)

        layoutManager.enumerateTextLayoutFragments(from: contentStorage.documentRange.location, options: [.ensuresLayout]) { fragment in
            fragment.draw(at: fragment.layoutFragmentFrame.origin, in: ctx)
            return true
        }
        NSGraphicsContext.restoreGraphicsState()

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(Data("tk-snapshot: wrote \(path) (\(Int(width))x\(Int(height)))\n".utf8))
        }
    }

    /// Selection/copy verification for the concealment mechanism (M6-PLAN §8
    /// risk 5). Concealment is by zero-advance attributes, so display length ==
    /// store length and the backing characters are the raw source; this probe
    /// builds a real read-only `NSTextView`, selects all, copies, and asserts
    /// the pasteboard string equals the raw source — i.e. ⌘A + ⌘C yields
    /// SOURCE, with selection length == store length. Prints the result to
    /// stderr.
    static func copyProbe(text: String, blocks: [Block], theme: Theme, baseURL: URL?) {
        let contentStorage = NSTextContentStorage()
        let storage = NSTextStorage()
        contentStorage.textStorage = storage
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: MarcoReadingMetrics.contentMaxWidth, height: 1_000_000))
        layoutManager.textContainer = container

        let built = TextKitReadingStyler.build(text: text, blocks: blocks, theme: theme, baseURL: baseURL)
        storage.setAttributedString(built.storage)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: MarcoReadingMetrics.contentMaxWidth, height: 800),
                                  textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        layoutManager.ensureLayout(for: contentStorage.documentRange)

        textView.selectAll(nil)
        let selLen = textView.selectedRange().length
        NSPasteboard.general.clearContents()
        textView.copy(nil)
        let pasted = NSPasteboard.general.string(forType: .string) ?? ""

        let source = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let matchesSource = pasted == source
        let msg = "tk-copy-probe: storeLen=\(storage.length) selectionLen=\(selLen) copy==source? \(matchesSource) pastedLen=\(pasted.count)\n"
        FileHandle.standardError.write(Data(msg.utf8))
        if !matchesSource {
            let prefix = String(pasted.prefix(80)).replacingOccurrences(of: "\n", with: "\\n")
            FileHandle.standardError.write(Data("tk-copy-probe: pasted-prefix=\"\(prefix)\"\n".utf8))
        }
    }
}
#endif
