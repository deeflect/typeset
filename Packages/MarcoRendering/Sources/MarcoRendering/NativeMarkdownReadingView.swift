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
        view.autoresizingMask = [NSView.AutoresizingMask.width]
        view.textContainerInset = NSSize(width: theme.contentHorizontalPadding, height: theme.contentTopPadding)
        view.backgroundColor = NSColor(theme.background)
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
            document = input.document
            if let old {
                let splice = input.document.replacementRanges(from: old)
                view.textStorage?.replaceCharacters(in: splice.old, with: input.document.attributedString.attributedSubstring(from: splice.new))
            } else {
                view.textStorage?.setAttributedString(input.document.attributedString)
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
        fileprivate func copyCode(at index: Int) -> Bool {
            guard let code = view?.textStorage?.attribute(.marcoCopy, at: index, effectiveRange: nil) as? String else { return false }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            onCodeCopied?()
            return true
        }

        fileprivate func pulse(blockIDs: Set<String>) {
            guard let layout = view?.layoutManager, let document else { return }
            let ranges = document.blockRanges.filter { blockIDs.contains($0.id) }.map(\.range)
            let token = generation
            for range in ranges { layout.addTemporaryAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.18), forCharacterRange: range) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak layout] in
                guard let self, self.generation == token, let layout else { return }
                for range in ranges { layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range) }
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
                    guard let self, self.generation == current, decoded.image != nil, let view = self.view,
                          range.location < (view.textStorage?.length ?? 0) else { return }
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
            let inset = max(0, (scroll.contentView.bounds.width - 720) / 2)
            view.textContainerInset = NSSize(width: inset + 24, height: view.textContainerInset.height)
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
    private var contextCode: String?
    private var contextTaskIndex: Int?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }
    override func mouseMoved(with event: NSEvent) {
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        (coordinator?.isActionable(at: index) == true ? NSCursor.pointingHand : NSCursor.iBeam).set()
        super.mouseMoved(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if coordinator?.click(at: index) == true { return }
        super.mouseDown(with: event)
        let now = window?.mouseLocationOutsideOfEventStream ?? event.locationInWindow
        let moved = hypot(now.x - event.locationInWindow.x, now.y - event.locationInWindow.y) > 4
        if !moved, selectedRange().length <= 1, event.clickCount == 1 {
            if coordinator?.openImage(at: index) != true { _ = coordinator?.copyCode(at: index) }
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let menu = super.menu(for: event) ?? NSMenu()
        if let code = textStorage?.attribute(.marcoCopy, at: index, effectiveRange: nil) as? String {
            contextCode = code
            menu.insertItem(withTitle: "Copy Code", action: #selector(copyCode), keyEquivalent: "", at: 0).target = self
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
    @objc private func copyCode() {
        guard let contextCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(contextCode, forType: .string)
        coordinator?.codeCopied()
    }
    override func copy(_ sender: Any?) {
        let selected = selectedRange()
        guard selected.length > 0, let textStorage else { return }
        let rich = textStorage.attributedSubstring(from: selected)
        let plain = NSMutableString(string: rich.string)
        if let images = coordinator?.document?.images {
            for image in images.reversed() where NSLocationInRange(image.range.location, selected) {
                plain.replaceCharacters(in: NSRange(location: image.range.location - selected.location, length: image.range.length), with: image.alt.isEmpty ? "Image" : image.alt)
            }
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(plain as String, forType: .string)
        if let data = try? rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            pasteboard.setData(data, forType: .rtf)
        }
        if rich.string.contains("\u{FFFC}"),
           let data = try? rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) {
            pasteboard.setData(data, forType: .rtfd)
        }
    }
}
