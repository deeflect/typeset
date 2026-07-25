// M6 work in progress: the TextKit 2 reading surface is reachable only from
// the Debug menu's toggle and has no tables, task checkboxes, frontmatter chip
// or code-block chrome yet. Gated out of Release entirely so an unfinished
// feature isn't compiled into a shipping App Store binary (the Spike/ folder
// does the same).
#if DEBUG

import AppKit
import MarcoCore
import MarcoRendering
import SwiftUI

/// M6 Phase 1 (slice 1): a real, read-only TextKit 2 reading surface — one
/// `NSTextView` on `NSTextLayoutManager`/`NSTextContentStorage` whose backing
/// store is the raw Markdown source. Non-editable but fully selectable, so
/// continuous cross-block selection (the #1 complaint the per-`Text` stack
/// can't fix) comes for free. Styled by `TextKitReadingStyler` from the same
/// `Theme` tokens the shipping `MarcoRendering` reading view uses; link clicks
/// route through `DocumentLinkRouter` (the shipping policy). Reachable only via
/// the Debug toggle in `DocumentWindow`; never replaces `DocumentRenderer`.
struct TextKitReadingView: NSViewRepresentable {
    let text: String
    let blocks: [Block]
    let theme: Theme
    let model: WindowModel
    let documentURL: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, documentURL: documentURL)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let contentStorage = NSTextContentStorage()
        let textStorage = NSTextStorage()
        contentStorage.textStorage = textStorage

        let layoutManager = NSTextLayoutManager()
        let palette = ReadingDecorationPalette(theme: theme)
        let fragmentDelegate = MarcoReadingLayoutManagerDelegate(palette: palette)
        layoutManager.delegate = fragmentDelegate
        contentStorage.addTextLayoutManager(layoutManager)

        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container

        let textView = ReadingTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [NSView.AutoresizingMask.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 0, height: MarcoReadingMetrics.contentTopPadding)
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(theme.background)
        textView.linkTextAttributes = [NSAttributedString.Key.cursor: NSCursor.pointingHand]
        textView.delegate = context.coordinator
        textView.router = context.coordinator.router

        context.coordinator.textView = textView
        context.coordinator.contentStorage = contentStorage
        context.coordinator.layoutManager = layoutManager
        context.coordinator.fragmentDelegate = fragmentDelegate

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(theme.background)
        scrollView.documentView = textView
        context.coordinator.scrollView = scrollView

        context.coordinator.rebuild(text: text, blocks: blocks, theme: theme, preserveAnchor: false)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.router.model = model
        context.coordinator.model = model
        context.coordinator.documentURL = documentURL
        context.coordinator.router.documentURL = documentURL
        context.coordinator.textView?.router = context.coordinator.router

        let coord = context.coordinator
        let themeChanged = coord.appliedColorScheme != theme.colorScheme || coord.appliedScale != theme.scale
        let textChanged = coord.appliedText != text
        guard themeChanged || textChanged else { return }
        if themeChanged {
            coord.textView?.backgroundColor = NSColor(theme.background)
            scrollView.backgroundColor = NSColor(theme.background)
        }
        // Both restyle (theme) and live reload (text) preserve the reader's
        // place: capture the top-of-viewport anchor, rebuild, restore it.
        coord.rebuild(text: text, blocks: blocks, theme: theme, preserveAnchor: true)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var model: WindowModel
        var documentURL: URL?
        var router: DocumentLinkRouter

        weak var scrollView: NSScrollView?
        weak var textView: ReadingTextView?
        var contentStorage: NSTextContentStorage?
        var layoutManager: NSTextLayoutManager?
        var fragmentDelegate: MarcoReadingLayoutManagerDelegate?

        var appliedText: String = "\u{0}"  // sentinel: never equal to real source
        var appliedColorScheme: ColorScheme?
        var appliedScale: CGFloat = -1
        private var appliedBlocks: [Block] = []

        init(model: WindowModel, documentURL: URL?) {
            self.model = model
            self.documentURL = documentURL
            // Inline-code click-to-copy: same pasteboard contract as the
            // shipping reading view (the in-place chip flash is a view concern
            // deferred to a later slice).
            self.router = DocumentLinkRouter(model: model, documentURL: documentURL) { code, _ in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            }
        }

        // MARK: styling / reload

        func rebuild(text: String, blocks: [Block], theme: Theme, preserveAnchor: Bool) {
            guard let contentStorage, let storage = contentStorage.textStorage else { return }
            let textChanged = appliedText != text
            let anchor = preserveAnchor ? captureAnchor(oldBlocks: appliedBlocks) : nil

            fragmentDelegate?.palette = ReadingDecorationPalette(theme: theme)
            fragmentDelegate?.backingScale = textView?.window?.backingScaleFactor ?? 2
            let result = TextKitReadingStyler.build(text: text, blocks: blocks, theme: theme, baseURL: documentURL)
            storage.setAttributedString(result.storage)

            appliedText = text
            appliedBlocks = blocks
            appliedColorScheme = theme.colorScheme
            appliedScale = theme.scale

            if let anchor {
                // Let layout settle for the new content, then restore the
                // reader's place: exact char offset for a same-text restyle,
                // block-identity remap when the source text actually changed.
                layoutManager?.ensureLayout(for: contentStorage.documentRange)
                restoreAnchor(anchor, newBlocks: blocks, textChanged: textChanged)
            }
        }

        // MARK: link handling

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url: URL?
            if let u = link as? URL { url = u }
            else if let s = link as? String { url = URL(string: s) }
            else { url = nil }
            guard let url else { return false }
            if router.route(url) { return true }
            NSWorkspace.shared.open(url)
            return true
        }

        // MARK: scroll anchor (M6-PLAN §8 risk 1 / BENCHMARKS Phase-0 follow-up)

        /// The top-of-viewport reading position, remembered across a rebuild.
        /// `blockID` (content-hash identity) survives a live reload where the
        /// raw character offset would not; `charIndex` restores an exact
        /// same-text restyle and is the fallback when the block changed.
        struct Anchor {
            var blockID: String?
            var charIndex: Int
            var pixelOffset: CGFloat
        }

        func captureAnchor(oldBlocks: [Block]) -> Anchor? {
            guard let textView, let layoutManager, let contentStorage else { return nil }
            let originY = textView.textContainerOrigin.y
            let topContainerY = textView.visibleRect.minY - originY
            let point = CGPoint(x: 0, y: max(0, topContainerY))
            guard let fragment = layoutManager.textLayoutFragment(for: point) else { return nil }
            let charIndex = contentStorage.offset(
                from: contentStorage.documentRange.location, to: fragment.rangeInElement.location)
            let pixelOffset = topContainerY - fragment.layoutFragmentFrame.minY
            let line = lineIndex(forCharacter: charIndex, in: textView.string as NSString)
            let blockID = blockID(forLine: line, blocks: oldBlocks, text: textView.string)
            return Anchor(blockID: blockID, charIndex: charIndex, pixelOffset: pixelOffset)
        }

        func restoreAnchor(_ anchor: Anchor, newBlocks: [Block], textChanged: Bool) {
            guard let textView, let layoutManager, let contentStorage, let scrollView else { return }
            let ns = textView.string as NSString

            var targetChar = min(anchor.charIndex, max(0, ns.length - 1))
            if let id = anchor.blockID, textChanged {
                if let line = startLine(ofBlockID: id, blocks: newBlocks, text: textView.string) {
                    targetChar = min(characterOffset(ofLine: line, in: ns), max(0, ns.length - 1))
                }
            }

            guard let location = contentStorage.location(
                contentStorage.documentRange.location, offsetBy: targetChar),
                let fragment = layoutManager.textLayoutFragment(for: location)
            else { return }

            let originY = textView.textContainerOrigin.y
            let targetContainerY = fragment.layoutFragmentFrame.minY + anchor.pixelOffset
            let targetViewY = targetContainerY + originY
            let clamped = max(0, min(targetViewY, max(0, textView.bounds.height - scrollView.contentView.bounds.height)))
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: clamped))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // MARK: line/block mapping

        private func lineIndex(forCharacter charIndex: Int, in ns: NSString) -> Int {
            guard charIndex > 0, charIndex <= ns.length else { return 0 }
            var line = 0
            ns.enumerateSubstrings(in: NSRange(location: 0, length: charIndex), options: [.byLines, .substringNotRequired]) { _, _, _, _ in
                line += 1
            }
            return max(0, line - 1)
        }

        private func characterOffset(ofLine targetLine: Int, in ns: NSString) -> Int {
            var line = 0
            var offset = 0
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, _, enclosing, stop in
                if line == targetLine { offset = enclosing.location; stop.pointee = true }
                line += 1
            }
            return offset
        }

        private func blockID(forLine line: Int, blocks: [Block], text: String) -> String? {
            let bodyOffset = MarkdownParser.bodyLineOffset(in: text)
            for block in blocks {
                let start = (block.kind == .frontmatter) ? 0 : block.startLine + bodyOffset
                let count = max(1, block.rawText.isEmpty ? 1 : block.rawText.components(separatedBy: "\n").count)
                if line >= start, line < start + count { return block.id }
            }
            return nil
        }

        private func startLine(ofBlockID id: String, blocks: [Block], text: String) -> Int? {
            let bodyOffset = MarkdownParser.bodyLineOffset(in: text)
            guard let block = blocks.first(where: { $0.id == id }) else { return nil }
            return (block.kind == .frontmatter) ? 0 : block.startLine + bodyOffset
        }
    }
}

/// `NSTextView` subclass that centers the reading column (like the shipping
/// view's 720pt measure) by keeping the text container inset symmetric as the
/// window resizes, and adds a hover underline on links (the pointing-hand
/// cursor comes from `linkTextAttributes`).
final class ReadingTextView: NSTextView {
    var router: DocumentLinkRouter?
    private var hoveredLinkRange: NSRange?
    private var trackingArea: NSTrackingArea?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let width = newSize.width
        let column = min(width - MarcoReadingMetrics.contentHorizontalPadding * 2, MarcoReadingMetrics.contentMaxWidth)
        let sideInset = max(MarcoReadingMetrics.contentHorizontalPadding, (width - max(column, 0)) / 2)
        if abs(textContainerInset.width - sideInset) > 0.5 {
            textContainerInset = NSSize(width: sideInset, height: MarcoReadingMetrics.contentTopPadding)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        guard let storage = textStorage, storage.length > 0 else { clearHover(); return }
        let index = characterIndexForInsertion(at: point)
        guard index >= 0, index < storage.length else { clearHover(); return }
        var range = NSRange(location: 0, length: 0)
        if storage.attribute(.link, at: index, effectiveRange: &range) != nil {
            setHover(range)            // real link: pointing hand (linkTextAttributes) + hover underline
        } else if storage.attribute(.marcoCopyText, at: index, effectiveRange: nil) != nil {
            clearHover()
            NSCursor.pointingHand.set()  // inline-code chip: pointer, no underline
        } else {
            clearHover()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let storage = textStorage, storage.length > 0 {
            let index = characterIndexForInsertion(at: point)
            if index >= 0, index < storage.length,
               let code = storage.attribute(.marcoCopyText, at: index, effectiveRange: nil) as? String,
               let url = InlineCodeCopy.url(for: code) {
                router?.route(url)      // same copy path as the shipping view
                return                  // don't also begin a selection drag
            }
        }
        super.mouseDown(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearHover()
    }

    private func setHover(_ range: NSRange) {
        guard hoveredLinkRange != range else { return }
        clearHover()
        textStorage?.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        hoveredLinkRange = range
    }

    private func clearHover() {
        guard let range = hoveredLinkRange, let storage = textStorage,
              range.location + range.length <= storage.length else { hoveredLinkRange = nil; return }
        storage.removeAttribute(.underlineStyle, range: range)
        hoveredLinkRange = nil
    }
}

#endif
