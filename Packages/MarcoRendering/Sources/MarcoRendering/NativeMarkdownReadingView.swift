import AppKit
import ImageIO
import SwiftUI

/// TextKit 1 reading surface. The source editor remains a separate text view.
public struct NativeMarkdownReadingView: NSViewRepresentable {
    public let document: NativeMarkdownDocument
    public let theme: Theme
    public let controller: Controller
    public var onCheckbox: ((Int, Int, Bool) -> Void)?
    public var onLink: ((URL) -> Bool)?
    public var onImageAccess: ((URL) -> Void)?
    public var onImageOpen: ((NSImage) -> Void)?
    public var onVisibleBlock: ((String?) -> Void)?
    public var onMetadataToggle: (() -> Void)?
    public var onCodeCopied: (() -> Void)?

    public init(document: NativeMarkdownDocument, theme: Theme, controller: Controller,
                onCheckbox: ((Int, Int, Bool) -> Void)? = nil,
                onLink: ((URL) -> Bool)? = nil,
                onImageAccess: ((URL) -> Void)? = nil,
                onImageOpen: ((NSImage) -> Void)? = nil,
                onVisibleBlock: ((String?) -> Void)? = nil,
                onMetadataToggle: (() -> Void)? = nil,
                onCodeCopied: (() -> Void)? = nil) {
        self.document = document
        self.theme = theme
        self.controller = controller
        self.onCheckbox = onCheckbox
        self.onLink = onLink
        self.onImageAccess = onImageAccess
        self.onImageOpen = onImageOpen
        self.onVisibleBlock = onVisibleBlock
        self.onMetadataToggle = onMetadataToggle
        self.onCodeCopied = onCodeCopied
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.allowsNonContiguousLayout = true
        let view = ReadingTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.usesFindBar = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        // Default maxSize is the initial frame, which caps the document at one viewport and blocks scrolling to the end.
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [NSView.AutoresizingMask.width]
        view.textContainerInset = NSSize(width: theme.contentHorizontalPadding, height: theme.contentTopPadding)
        view.backgroundColor = NSColor(theme.background)
        view.linkTextAttributes = [.foregroundColor: NSColor(theme.linkColor), .cursor: NSCursor.pointingHand]
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = view
        scroll.backgroundColor = NSColor(theme.background)
        context.coordinator.attach(view: view, scroll: scroll, controller: controller)
        context.coordinator.apply(self, preserve: false)
        return scroll
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.apply(self, preserve: true)
    }

    public static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.cancel()
        coordinator.controller?.view = nil
        coordinator.view?.delegate = nil
        coordinator.view?.coordinator = nil
    }

    @MainActor public final class Controller {
        fileprivate weak var view: ReadingTextView?
        fileprivate weak var coordinator: Coordinator?
        private var pendingBlockID: String?
        private var pendingPulseIDs: Set<String> = []
        private var pendingFindAction: NSTextFinder.Action?
        public init() {}
        public func jump(toBlock id: String) {
            guard let range = coordinator?.document?.blockRanges.first(where: { $0.id == id })?.range else {
                pendingBlockID = id
                return
            }
            pendingBlockID = nil
            view?.scrollRangeToVisible(NSRange(location: range.location, length: 0))
        }
        public func queueJump(toBlock id: String) { pendingBlockID = id }
        fileprivate func applyPendingJump() {
            if let pendingBlockID { jump(toBlock: pendingBlockID) }
        }
        public func showFind() { find(.showFindInterface) }
        public func findNext() { find(.nextMatch) }
        public func findPrevious() { find(.previousMatch) }
        private func find(_ action: NSTextFinder.Action) {
            guard let view else { pendingFindAction = action; return }
            let item = NSMenuItem()
            item.tag = action.rawValue
            view.performFindPanelAction(item)
        }
        fileprivate func applyPendingFind() {
            if let pendingFindAction {
                self.pendingFindAction = nil
                find(pendingFindAction)
            }
        }
        public func selectAll() { view?.selectAll(nil) }
        public func copy() { view?.copy(nil) }
        public func retryImages() { coordinator?.retryImages() }
        public func pulse(blockIDs: Set<String>) { coordinator?.pulse(blockIDs: blockIDs) }
        public func queuePulse(blockIDs: Set<String>) { pendingPulseIDs.formUnion(blockIDs) }
        fileprivate func applyPendingPulse() {
            guard !pendingPulseIDs.isEmpty else { return }
            coordinator?.pulse(blockIDs: pendingPulseIDs)
            pendingPulseIDs.removeAll()
        }
        /// Persistent quiet gutter bars ("changed since last viewed"), kept
        /// across reloads for blocks whose id survives. Empty set clears.
        public private(set) var changedBlockIDs: Set<String> = []
        public func markChanged(blockIDs: Set<String>) {
            changedBlockIDs = blockIDs
            coordinator?.updateMarkers()
        }
        /// The reader's selection as plain text (task boxes/images spelled
        /// out, like Copy) plus the ids of the blocks it touches, in order.
        public func selection() -> (text: String, blockIDs: [String])? {
            guard let view, let document = coordinator?.document else { return nil }
            let selected = view.selectedRange()
            guard selected.length > 0 else { return nil }
            let ids = document.blockRanges.filter { NSIntersectionRange($0.range, selected).length > 0 }.map(\.id)
            return (view.plainText(in: selected), ids)
        }
    }

    @MainActor public final class Coordinator: NSObject, NSTextViewDelegate {
        fileprivate weak var view: ReadingTextView?
        fileprivate weak var scroll: NSScrollView?
        fileprivate weak var controller: Controller?
        fileprivate var document: NativeMarkdownDocument?
        private var onCheckbox: ((Int, Int, Bool) -> Void)?
        private var onLink: ((URL) -> Bool)?
        private var onImageAccess: ((URL) -> Void)?
        private var onImageOpen: ((NSImage) -> Void)?
        private var onVisibleBlock: ((String?) -> Void)?
        private var onMetadataToggle: (() -> Void)?
        private var onCodeCopied: (() -> Void)?
        private var generation = 0
        private var tasks: [Task<Void, Never>] = []
        private var loadedImageLocations: Set<Int> = []
        private var loadedImages: [Int: NativeMarkdownImages.Decoded] = [:]
        private var loadedCodeLocations: Set<Int> = []
        private var highlightIsDark = false
        private var pendingVisibleID: String?
        private var reportedVisibleID: String?
        private var hasReportedVisible = false
        private var visibleNotificationScheduled = false
        private var measure: CGFloat = 680
        private var minimumGutter: CGFloat = 28
        private var pulseToken = 0

        fileprivate func attach(view: ReadingTextView, scroll: NSScrollView, controller: Controller) {
            self.view = view
            self.scroll = scroll
            self.controller = controller
            controller.view = view
            controller.coordinator = self
            DispatchQueue.main.async { [weak controller] in controller?.applyPendingFind() }
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.contentView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSView.frameDidChangeNotification, object: scroll.contentView)
            resized()
        }

        fileprivate func apply(_ input: NativeMarkdownReadingView, preserve: Bool) {
            guard let view, let scroll else { return }
            onCheckbox = input.onCheckbox
            onLink = input.onLink
            onImageAccess = input.onImageAccess
            onImageOpen = input.onImageOpen
            onVisibleBlock = input.onVisibleBlock
            onMetadataToggle = input.onMetadataToggle
            onCodeCopied = input.onCodeCopied
            let old = document
            let changed = old?.attributedString !== input.document.attributedString
            if measure != input.theme.contentMaxWidth || minimumGutter != input.theme.contentHorizontalPadding {
                measure = input.theme.contentMaxWidth
                minimumGutter = input.theme.contentHorizontalPadding
                resized()
            }
            view.backgroundColor = NSColor(input.theme.background)
            scroll.backgroundColor = NSColor(input.theme.background)
            guard changed else { return }
            let selection = view.selectedRange()
            let top = preserve ? view.characterIndexForInsertion(at: NSPoint(x: view.textContainerInset.width, y: view.visibleRect.minY)) : 0
            let anchorBlock = old?.block(at: top)
            let anchorID = anchorBlock?.id
            let anchorOffset = anchorBlock.map { top - $0.range.location } ?? 0
            let oldGlyph = view.layoutManager?.glyphRange(forCharacterRange: NSRange(location: top, length: top < view.string.utf16.count ? 1 : 0), actualCharacterRange: nil)
            let oldY = oldGlyph.flatMap { view.layoutManager?.boundingRect(forGlyphRange: $0, in: view.textContainer!).minY } ?? 0
            let pixelOffset = view.visibleRect.minY - oldY
            cancelImages()
            pulseToken += 1
            view.ticks = []
            document = input.document
            updateMarkers()
            if let old {
                let splice = input.document.replacementRanges(from: old)
                view.textStorage?.replaceCharacters(in: splice.old,
                    with: input.document.materializedAttributedString(in: splice.new))
            } else {
                view.textStorage?.setAttributedString(input.document.materializedAttributedString())
            }
            if let old, let remapped = input.document.remappedSelection(selection, from: old) {
                view.setSelectedRange(remapped)
            } else {
                view.setSelectedRange(NSRange(location: min(selection.location, view.string.utf16.count), length: 0))
            }
            if let anchorID, let range = input.document.blockRanges.first(where: { $0.id == anchorID })?.range {
                let location = range.location + min(anchorOffset, range.length)
                view.scrollRangeToVisible(NSRange(location: location, length: 0))
                if let layout = view.layoutManager, let container = view.textContainer {
                    let glyph = layout.glyphRange(forCharacterRange: NSRange(location: location, length: location < view.string.utf16.count ? 1 : 0), actualCharacterRange: nil)
                    let y = layout.boundingRect(forGlyphRange: glyph, in: container).minY + pixelOffset
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
            loadedImageLocations.removeAll()
            loadedImages.removeAll()
            loadedCodeLocations.removeAll()
            highlightIsDark = input.theme.colorScheme == .dark
            scrolled()
            DispatchQueue.main.async { [weak self] in self?.scrolled() }
            controller?.applyPendingJump()
            controller?.applyPendingPulse()
        }

        @objc private func scrolled() {
            guard let view, let document else { return }
            let point = NSPoint(x: view.textContainerInset.width, y: view.visibleRect.minY + view.textContainerInset.height)
            let index = view.characterIndexForInsertion(at: point)
            pendingVisibleID = document.block(at: index)?.id
            if !visibleNotificationScheduled {
                visibleNotificationScheduled = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.visibleNotificationScheduled = false
                    let id = self.pendingVisibleID
                    guard !self.hasReportedVisible || self.reportedVisibleID != id else { return }
                    self.reportedVisibleID = id
                    self.hasReportedVisible = true
                    self.onVisibleBlock?(id)
                }
            }
            loadVisibleImages()
            loadVisibleHighlights()
        }

        fileprivate func click(at index: Int) -> Bool {
            if view?.textStorage?.attribute(.link, at: index, effectiveRange: nil) != nil { return false }
            if view?.textStorage?.attribute(.marcoMetadata, at: index, effectiveRange: nil) != nil {
                onMetadataToggle?()
                return onMetadataToggle != nil
            }
            if let task = document?.checkboxes.first(where: { NSLocationInRange(index, $0.range) }) {
                onCheckbox?(task.blockStartLine, task.lineOffset, !task.checked)
                return onCheckbox != nil
            }
            return false
        }
        fileprivate func openImage(at index: Int) -> Bool {
            if let image = document?.images.first(where: { NSLocationInRange(index, $0.range) }), let url = image.url {
                if let actual = loadedImages[image.range.location]?.image {
                    onImageOpen?(actual)
                } else if url.isFileURL, FolderAccessStore.isAccessDenied(at: url) {
                    onImageAccess?(url.deletingLastPathComponent())
                }
                return true
            }
            return false
        }
        fileprivate func codeCopied() { onCodeCopied?() }
        fileprivate func checkbox(at index: Int) -> NativeMarkdownDocument.Checkbox? {
            document?.checkboxes.first(where: { NSLocationInRange(index, $0.range) })
        }
        fileprivate func isActionable(at index: Int) -> Bool {
            guard let view, index < (view.textStorage?.length ?? 0) else { return false }
            return view.textStorage?.attribute(.link, at: index, effectiveRange: nil) != nil
                || view.textStorage?.attribute(.marcoCopy, at: index, effectiveRange: nil) != nil
                || (onMetadataToggle != nil && view.textStorage?.attribute(.marcoMetadata, at: index, effectiveRange: nil) != nil)
                || (onCheckbox != nil && checkbox(at: index) != nil)
                || document?.images.contains(where: { NSLocationInRange(index, $0.range) }) == true
        }
        fileprivate func toggleTask(at index: Int) -> Bool {
            guard let task = checkbox(at: index), let onCheckbox else { return false }
            onCheckbox(task.blockStartLine, task.lineOffset, !task.checked)
            return true
        }

        /// Board 04: a 3 pt accent tick in the left gutter beside each changed block, held 2 s, then faded.
        fileprivate func pulse(blockIDs: Set<String>) {
            guard let view, let document else { return }
            let ranges = document.blockRanges.filter { blockIDs.contains($0.id) }.map(\.range)
            guard !ranges.isEmpty else { return }
            pulseToken += 1
            let token = pulseToken
            view.ticks = ranges.map { ($0, 1) }
            view.needsDisplay = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.fadeTicks(token, step: 1) }
        }

        fileprivate func updateMarkers() {
            guard let view else { return }
            let ids = controller?.changedBlockIDs ?? []
            view.markers = ids.isEmpty ? [] : (document?.blockRanges ?? []).filter { ids.contains($0.id) }.map(\.range)
            view.needsDisplay = true
        }

        private func fadeTicks(_ token: Int, step: Int) {
            guard token == pulseToken, let view else { return }
            let steps = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 10
            let alpha = 1 - CGFloat(step) / CGFloat(steps)
            view.ticks = alpha <= 0 ? [] : view.ticks.map { ($0.range, alpha) }
            view.needsDisplay = true
            if alpha > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.fadeTicks(token, step: step + 1) }
            }
        }

        public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            return onLink?(url) ?? NSWorkspace.shared.open(url)
        }

        private func loadVisibleImages() {
            guard let view, let images = document?.images else { return }
            let top = view.characterIndexForInsertion(at: NSPoint(x: view.textContainerInset.width, y: view.visibleRect.minY))
            let bottom = view.characterIndexForInsertion(at: NSPoint(x: view.textContainerInset.width, y: view.visibleRect.maxY + view.visibleRect.height))
            let current = generation
            for image in images {
                guard let url = image.url, url.isFileURL else { continue } // Documents never fetch network images.
                let range = image.range
                guard range.location >= top, range.location <= bottom, loadedImageLocations.insert(range.location).inserted else { continue }
                let task = Task { [weak self] in
                    let decoded = await NativeMarkdownImages.load(url)
                    guard let self, self.generation == current, let view = self.view,
                          range.location < (view.textStorage?.length ?? 0) else { return }
                    guard decoded.image != nil else {
                        let blocked = await Task.detached { FolderAccessStore.isAccessDenied(at: url) }.value
                        guard self.generation == current,
                              let cell = (view.textStorage?.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment)?.attachmentCell as? ImagePlaceholderCell else { return }
                        cell.loadState = blocked ? .blocked : .missing
                        view.layoutManager?.invalidateDisplay(forCharacterRange: range)
                        return
                    }
                    self.loadedImages[range.location] = decoded
                    let width = max(120, view.textContainer?.containerSize.width ?? 600)
                    let attachment = NativeMarkdownImages.attachment(for: decoded, maxWidth: width)
                    view.textStorage?.addAttribute(.attachment, value: attachment, range: range)
                }
                tasks.append(task)
            }
        }

        private func loadVisibleHighlights() {
            guard let view, let ranges = document?.codeRanges else { return }
            let top = view.characterIndexForInsertion(at: NSPoint(x: view.textContainerInset.width, y: view.visibleRect.minY))
            let bottom = view.characterIndexForInsertion(at: NSPoint(x: view.textContainerInset.width, y: view.visibleRect.maxY + view.visibleRect.height))
            let current = generation
            let isDark = highlightIsDark
            for code in ranges where code.language != nil {
                guard code.range.location + code.range.length >= top,
                      code.range.location <= bottom,
                      loadedCodeLocations.insert(code.range.location).inserted else { continue }
                let task = Task { [weak self] in
                    guard let ns = await CodeHighlighter.shared.highlightedNative(code: code.code, language: code.language, isDark: isDark) else { return }
                    guard let self, self.generation == current, let storage = self.view?.textStorage,
                          code.range.location + code.range.length <= storage.length, ns.length == code.range.length else { return }
                    ns.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: ns.length)) { value, range, _ in
                        if let value { storage.addAttribute(.foregroundColor, value: value, range: NSRange(location: code.range.location + range.location, length: range.length)) }
                    }
                }
                tasks.append(task)
            }
        }

        private func cancelImages() {
            generation += 1
            tasks.forEach { $0.cancel() }
            tasks.removeAll()
        }
        @objc private func resized() {
            guard let view, let scroll else { return }
            let inset = max(minimumGutter, (scroll.contentView.bounds.width - measure) / 2)
            view.textContainerInset = NSSize(width: inset, height: view.textContainerInset.height)
            let width = max(120, view.textContainer?.containerSize.width ?? 600)
            for (location, image) in loadedImages where location < (view.textStorage?.length ?? 0) {
                view.textStorage?.addAttribute(.attachment, value: NativeMarkdownImages.attachment(for: image, maxWidth: width), range: NSRange(location: location, length: 1))
            }
            scrolled()
        }
        fileprivate func retryImages() {
            cancelImages()
            loadedImageLocations.removeAll()
            loadedImages.removeAll()
            loadedCodeLocations.removeAll()
            loadVisibleImages()
            loadVisibleHighlights()
        }
        fileprivate func cancel() {
            cancelImages()
            NotificationCenter.default.removeObserver(self)
        }
    }
}

private final class ReadingTextView: NSTextView {
    weak var coordinator: NativeMarkdownReadingView.Coordinator?
    /// Change ticks (character range, opacity), drawn in the left gutter.
    var ticks: [(range: NSRange, alpha: CGFloat)] = []
    /// Changed-since-last-viewed bars: same spot as ticks, quieter, persistent.
    var markers: [NSRange] = []
    private var contextCodeIndex: Int?
    private var contextTaskIndex: Int?
    private weak var hoveredCopyBlock: MarcoTextBlock?
    private weak var copiedBlock: MarcoTextBlock?
    private var copyGeneration = 0
    private var hoverArea: NSTrackingArea?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !ticks.isEmpty || !markers.isEmpty, let layout = layoutManager, let container = textContainer, let length = textStorage?.length else { return }
        let origin = textContainerOrigin
        let bars = markers.map { (range: $0, alpha: CGFloat(0.4)) } + ticks
        for tick in bars where NSMaxRange(tick.range) <= length {
            let content = NSRange(location: tick.range.location, length: max(0, tick.range.length - 1))
            let glyphs = layout.glyphRange(forCharacterRange: content, actualCharacterRange: nil)
            let bounds = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let rect = NSRect(x: origin.x - 24, y: origin.y + bounds.minY + 3, width: 3, height: max(6, bounds.height - 6))
            guard rect.intersects(dirtyRect) else { continue }
            NSColor.controlAccentColor.withAlphaComponent(tick.alpha).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverArea == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let copy = copyButton(at: point)
        setHoveredCopy(copy)
        // Code card bodies select like text; only their Copy label is a button.
        let actionable = copy != nil || (codeBlock(at: index) == nil && coordinator?.isActionable(at: index) == true)
        (actionable ? NSCursor.pointingHand : NSCursor.iBeam).set()
        super.mouseMoved(with: event)
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredCopy(nil)
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let copy = copyButton(at: point) { copyCode(at: copy.range.location); return }
        let index = characterIndexForInsertion(at: point)
        if coordinator?.click(at: index) == true { return }
        super.mouseDown(with: event)
        let now = window?.mouseLocationOutsideOfEventStream ?? event.locationInWindow
        let moved = hypot(now.x - event.locationInWindow.x, now.y - event.locationInWindow.y) > 4
        if !moved, selectedRange().length <= 1, event.clickCount == 1 {
            if coordinator?.openImage(at: index) != true, codeBlock(at: index) == nil { copyCode(at: index) }
        }
    }

    // MARK: Code card Copy label

    /// The code card holding `index`, its character range and its frame in view coordinates.
    private func codeBlock(at index: Int) -> (block: MarcoTextBlock, range: NSRange, frame: NSRect)? {
        guard let layout = layoutManager, let storage = textStorage, storage.length > 0 else { return nil }
        let index = min(index, storage.length - 1)
        guard let style = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle,
              let block = style.textBlocks.first as? MarcoTextBlock, case .code = block.kind else { return nil }
        let range = storage.range(of: block, at: index)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let frame = layout.boundsRect(for: block, glyphRange: glyphs).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        return (block, range, frame)
    }
    private func copyButton(at point: NSPoint) -> (block: MarcoTextBlock, range: NSRange, frame: NSRect)? {
        // The label sits in the card's top padding, which maps to the newline just before the card.
        let index = characterIndexForInsertion(at: point)
        for candidate in [index, index + 1] {
            if let hit = codeBlock(at: candidate), hit.block.copyHitRect(inFrame: hit.frame).contains(point) { return hit }
        }
        return nil
    }
    private func setHoveredCopy(_ hit: (block: MarcoTextBlock, range: NSRange, frame: NSRect)?) {
        guard hit?.block !== hoveredCopyBlock else { return }
        if let old = hoveredCopyBlock, old.copyState == .hover { old.copyState = .idle }
        hoveredCopyBlock = hit?.block
        if let block = hit?.block, block.copyState == .idle { block.copyState = .hover }
        setNeedsDisplay(visibleRect)
    }
    /// Code cards confirm in place ("Copied" for 1.5 s); inline code has no label, so the window shows its toast.
    private func copyCode(at index: Int) {
        guard let storage = textStorage, index < storage.length,
              let code = storage.attribute(.marcoCopy, at: index, effectiveRange: nil) as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        guard let block = codeBlock(at: index)?.block else { coordinator?.codeCopied(); return }
        if let old = copiedBlock, old !== block { old.copyState = old === hoveredCopyBlock ? .hover : .idle }
        block.copyState = .copied
        copiedBlock = block
        copyGeneration &+= 1
        let generation = copyGeneration
        setNeedsDisplay(visibleRect)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, generation == self.copyGeneration, let block = self.copiedBlock else { return }
            block.copyState = block === self.hoveredCopyBlock ? .hover : .idle
            self.setNeedsDisplay(self.visibleRect)
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let menu = super.menu(for: event) ?? NSMenu()
        if textStorage?.attribute(.marcoCopy, at: index, effectiveRange: nil) is String {
            contextCodeIndex = index
            menu.insertItem(withTitle: "Copy Code", action: #selector(copyCodeFromMenu), keyEquivalent: "", at: 0).target = self
        }
        if coordinator?.checkbox(at: index) != nil {
            contextTaskIndex = index
            let checked = coordinator?.checkbox(at: index)?.checked == true
            menu.insertItem(withTitle: checked ? "Mark as Not Done" : "Mark as Done", action: #selector(toggleTask), keyEquivalent: "", at: 0).target = self
        }
        return menu
    }
    @objc private func toggleTask() {
        if let contextTaskIndex { _ = coordinator?.toggleTask(at: contextTaskIndex) }
    }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", coordinator?.toggleTask(at: selectedRange().location) == true { return }
        super.keyDown(with: event)
    }
    @objc private func copyCodeFromMenu() {
        if let contextCodeIndex { copyCode(at: contextCodeIndex) }
    }
    override func copy(_ sender: Any?) {
        let selected = selectedRange()
        guard selected.length > 0, let textStorage else { return }
        let rich = textStorage.attributedSubstring(from: selected)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(plainText(in: selected), forType: .string)
        if let data = try? rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            pasteboard.setData(data, forType: .rtf)
        }
        if rich.string.contains("\u{FFFC}"),
           let data = try? rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) {
            pasteboard.setData(data, forType: .rtfd)
        }
    }
    /// Selected text with drawn stand-ins spelled out, shared by Copy and Copy as Quote.
    func plainText(in selected: NSRange) -> String {
        let plain = NSMutableString(string: (string as NSString).substring(with: selected))
        // Drawn stand-ins (task boxes, images) are U+FFFC in the text; give plain text words for them.
        var replacements: [(NSRange, String)] = []
        for image in coordinator?.document?.images ?? [] where NSLocationInRange(image.range.location, selected) {
            replacements.append((image.range, image.alt.isEmpty ? "Image" : image.alt))
        }
        for box in coordinator?.document?.checkboxes ?? [] where NSLocationInRange(box.range.location, selected) {
            replacements.append((NSRange(location: box.range.location, length: min(box.range.length, NSMaxRange(selected) - box.range.location)), box.checked ? "[x] " : "[ ] "))
        }
        for (range, text) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
            plain.replaceCharacters(in: NSRange(location: range.location - selected.location, length: range.length), with: text)
        }
        return plain as String
    }
}
