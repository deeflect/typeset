import AppKit
import MarcoCore
import Observation
import SwiftUI
import MarcoRendering

/// The per-window brain that sits above `DocumentReloadController`. It owns
/// everything that survives *across* files within one window — the
/// back/forward history, the outline sidebar's open state, the ⌘F session,
/// and remembered scroll positions — and swaps the underlying reload
/// controller when the user follows a relative link or steps history.
///
/// `DocumentWindow` creates exactly one of these and publishes it as a
/// `@FocusedValue`, so the app's real menu bar (`AppCommands`) can drive the
/// key window without per-window hidden buttons.
@Observable
@MainActor
final class WindowModel {
    /// The reload controller for whatever file is showing right now. Rebuilt
    /// on navigation; `nil` only for the empty-state window (no file).
    private(set) var controller: DocumentReloadController?

    /// ⌘F session (query, matches, current index). Lives here so it persists
    /// across navigation and survives live reloads.
    let find = FindSession()

    /// The heading whose section currently contains the top of the viewport,
    /// tracked off the reading view's scroll position (debounced). Drives the
    /// checkmark in the outline dropdown (⌘1 / toolbar). `nil` until the first
    /// scroll signal or in a document with no headings.
    private(set) var currentOutlineID: String?
    private var outlineTrackTask: Task<Void, Never>?
    /// After the dropdown jumps to a heading we set `currentOutlineID`
    /// optimistically; the scroll tracker would otherwise re-derive it on its
    /// debounce and flicker. Ignore tracker updates until this instant.
    private var suppressOutlineTrackingUntil: Date = .distantPast
    /// The toolbar's outline button view, captured so ⌘1 can pop the native
    /// menu up anchored to it (mouse clicks anchor to it directly).
    weak var outlineAnchor: NSView?

    /// True while Edit ▸ Select All has claimed the whole document.
    ///
    /// The reading view is a stack of per-block `Text` views, and SwiftUI text
    /// selection cannot span two of them — dragging across the document only
    /// ever selects within one block, which is why "copy the whole thing"
    /// didn't work. Select-all is therefore modelled explicitly: the reading
    /// view tints the entire content column, and Copy takes the whole
    /// document. (A real continuous selection needs the single-text-view
    /// reading surface M6 is building.)
    private(set) var isSelectAllActive = false

    /// Select All applies to a document that isn't already in the ⌘E source
    /// editor (which has its own, real, selection).
    var canSelectAllDocument: Bool { controller != nil && controller?.isEditing != true }

    func selectAllDocument() {
        guard canSelectAllDocument else { return }
        isSelectAllActive = true
    }

    func deselectAll() {
        guard isSelectAllActive else { return }
        isSelectAllActive = false
    }

    /// Edit ▸ Copy (⌘C) with the whole document selected. Puts RTF, HTML and
    /// plain Markdown on the pasteboard, same as ⇧⌘C.
    func copySelection() {
        guard isSelectAllActive else { return }
        copyAsRichText()
    }

    /// The image currently shown in the full-window lightbox (PLAN §6), or
    /// `nil` when none. Presented at the window's top level by `DocumentWindow`
    /// so it escapes the reading column's measure clipping.
    var lightboxImage: NSImage?

    /// A quiet, non-modal hint shown when a relative link points at a file we
    /// can't read (sandbox scope not granted). Never a modal (PLAN §4).
    private(set) var accessHint: String?
    /// Non-nil only while `accessHint` is showing *and* the failure looks
    /// like a sandbox denial (as opposed to a genuinely missing file) — the
    /// hint's "Allow access" action retries navigation to this URL.
    private(set) var accessHintAction: (title: String, url: URL)?
    private var hintClearTask: Task<Void, Never>?

    /// Owned here (not in `DocumentWindow`) so the ⌘E menu item can drive the
    /// same position-preserving edit-mode transition the toolbar toggle does.
    let editorHandle = SourceEditorHandle()
    /// The editor line to scroll to when entering edit mode, consumed by the
    /// `SourceEditorView`'s `onAppear`.
    var pendingEditorScrollLine: Int?

    /// The current reading `Theme`, pushed down by `DocumentWindow`, so menu
    /// actions (Export PDF / Copy as Rich Text / Print) can render with the
    /// exact appearance on screen without a view in scope.
    var readingTheme = Theme(colorScheme: .light, scale: 1)

    weak var window: NSWindow? {
        didSet {
            guard window !== oldValue else { return }
            controller?.window = window
            applyWindowIdentity()
            observeLiveResize(of: window)
        }
    }

    /// Keeps the window's `title` and `representedURL` pointed at the live
    /// document. The title bar itself is hidden (`.hiddenTitleBar`), but the
    /// title is what the Window menu, Mission Control, ⌘` cycling and the
    /// proxy-icon menu display — leaving it unset is why every window used to
    /// read as an indistinguishable "Marco".
    private func applyWindowIdentity() {
        guard let window else { return }
        window.representedURL = currentURL
        window.title = currentURL?.lastPathComponent ?? Bundle.main.displayName
    }

    /// True while the window is in a live-resize drag. Read imperatively (not in
    /// a view `body`) to skip non-essential per-frame work — outline tracking's
    /// O(n) section scan and the heading-offset probes — so the reading column
    /// re-wraps without also churning that work each frame.
    private(set) var isLiveResizing = false
    private var liveResizeObservers: [NSObjectProtocol] = []

    private func observeLiveResize(of window: NSWindow?) {
        liveResizeObservers.forEach { NotificationCenter.default.removeObserver($0) }
        liveResizeObservers.removeAll()
        isLiveResizing = false
        guard let window else { return }
        let center = NotificationCenter.default
        liveResizeObservers.append(center.addObserver(
            forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.isLiveResizing = true } })
        liveResizeObservers.append(center.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.isLiveResizing = false } })
    }

    // MARK: - History

    private(set) var history: [URL] = []
    private(set) var historyIndex = -1

    var currentURL: URL? { history.indices.contains(historyIndex) ? history[historyIndex] : nil }
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex >= 0 && historyIndex < history.count - 1 }

    /// Session (and lightly persisted) per-file scroll anchor: file path →
    /// the block id that was at the top of the viewport.
    private var scrollMemory: [String: String] = [:]

    // MARK: - Lifecycle

    /// Called once per window from `.task(id:)`. `nil` ⇒ empty-state window.
    func load(initial url: URL?) {
        guard let url, controller == nil else { return }
        let std = url.standardizedFileURL
        history = [std]
        historyIndex = 0
        activate(std, restoreScroll: true)
    }

    func stop() {
        controller?.stop()
        hintClearTask?.cancel()
        liveResizeObservers.forEach { NotificationCenter.default.removeObserver($0) }
        liveResizeObservers.removeAll()
    }

    private func activate(_ url: URL, restoreScroll: Bool) {
        deselectAll()
        controller?.stop()
        let controller = DocumentReloadController(url: url)
        controller.window = window
        // Reuse the bench-only reload hook (unused in the live app) to keep the
        // open find session in lockstep with the document as it reloads.
        controller.onReloadApplied = { [weak self] _ in
            guard let self, self.find.isActive else { return }
            self.find.rebuildSegments(from: controller.blocks)
        }
        self.controller = controller
        controller.start()
        // Standard document proxy behaviors (⌘-click path menu, title drag)
        // come free from representedURL; keep it — and the Window-menu title —
        // pointed at the live document as history/navigation swaps the
        // controller.
        applyWindowIdentity()
        // Remember this document for the empty-state home screen (PLAN §6).
        RecentDocumentsStore.shared.record(url)

        if find.isActive {
            find.rebuildSegments(from: controller.blocks)
        }
        if restoreScroll, let anchor = savedAnchor(for: url),
           controller.blocks.contains(where: { $0.id == anchor }) {
            controller.scrollPosition.scrollTo(id: anchor)
        }
    }

    // MARK: - Navigation (relative .md links + back/forward)

    /// Opens `target` in this same window, replacing content and re-wiring the
    /// watcher. If the file can't be read (sandbox scope not granted), leaves
    /// the current document untouched and surfaces a quiet hint.
    func navigate(to target: URL) {
        let std = target.standardizedFileURL
        guard std != currentURL?.standardizedFileURL else { return }
        guard canRead(std) else {
            presentAccessHint(for: std)
            return
        }
        saveScrollAnchor()
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(std)
        historyIndex = history.count - 1
        activate(std, restoreScroll: false)
    }

    func goBack() {
        guard canGoBack else { return }
        saveScrollAnchor()
        historyIndex -= 1
        activate(history[historyIndex], restoreScroll: true)
    }

    func goForward() {
        guard canGoForward else { return }
        saveScrollAnchor()
        historyIndex += 1
        activate(history[historyIndex], restoreScroll: true)
    }

    /// Cheap sandbox-aware readability probe: try to open the file for reading
    /// (respects the sandbox, unlike a POSIX-permission check) and close it.
    /// Consults `FolderAccessStore` first — an ancestor-folder grant keeps
    /// its security scope open for the process lifetime, so once granted
    /// this read just succeeds like any other file.
    private func canRead(_ url: URL) -> Bool {
        if FolderAccessStore.shared.access(to: url) { return true }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        try? handle.close()
        return true
    }

    private func presentAccessHint(for url: URL) {
        let folderName = url.deletingLastPathComponent().lastPathComponent
        if FolderAccessStore.isAccessDenied(at: url) {
            accessHint = "Can't open \(url.lastPathComponent) — allow access to \u{201c}\(folderName)\u{201d} to follow relative links there."
            accessHintAction = (title: "Allow Access\u{2026}", url: url)
        } else {
            accessHint = "Can't open \(url.lastPathComponent) — it's outside the folder you granted access to."
            accessHintAction = nil
        }
        hintClearTask?.cancel()
        hintClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.accessHint = nil
            self?.accessHintAction = nil
        }
    }

    func dismissAccessHint() {
        hintClearTask?.cancel()
        accessHint = nil
        accessHintAction = nil
    }

    /// The access-hint's "Allow access" affordance: presents the folder
    /// picker (never spontaneously — only from this explicit tap), stores
    /// the bookmark, and — on success — immediately retries the original
    /// navigation so the link resolves in place.
    func grantAccessFromHint() {
        guard let (_, url) = accessHintAction else { return }
        let folder = url.deletingLastPathComponent()
        let granted = FolderAccessStore.shared.requestAccess(
            defaultDirectory: folder,
            message: "Allow \(Bundle.main.displayName) to open files in \u{201c}\(folder.lastPathComponent)\u{201d}, so relative links between your Markdown files work.")
        guard granted != nil else { return }
        dismissAccessHint()
        navigate(to: url)
    }

    // MARK: - Anchor navigation (#heading) within the current doc

    /// Scrolls to the heading whose slugified text matches `fragment`
    /// (GitHub-style anchors). Returns true if a heading matched.
    @discardableResult
    func scrollToAnchor(_ fragment: String) -> Bool {
        guard let controller else { return false }
        let target = HeadingSlug.normalize(fragment)
        for block in controller.blocks {
            guard case .heading = block.kind else { continue }
            let slug = HeadingSlug.slug(BlockStructureCache.shared.headingText(for: block))
            if slug == target {
                controller.scrollPosition.scrollTo(id: block.id)
                return true
            }
        }
        return false
    }

    // MARK: - Find

    func openFind() {
        guard let controller else { return }
        deselectAll()
        find.open(blocks: controller.blocks)
    }

    func closeFind() { find.close() }

    /// Advances to the next/previous match and scrolls it into view.
    func findNext() { find.next(); scrollToCurrentMatch() }
    func findPrevious() { find.previous(); scrollToCurrentMatch() }

    func scrollToCurrentMatch() {
        guard let blockID = find.currentBlockID, let controller else { return }
        controller.scrollPosition.scrollTo(id: blockID)
    }

    // MARK: - Edit mode (⌘E), position-preserving in both directions

    func toggleEditMode() {
        guard let controller else { return }
        deselectAll()
        if controller.isEditing {
            let caretLine = editorHandle.caretLine()
            if let targetID = controller.exitEditMode(caretLine: caretLine) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { controller.scrollPosition.scrollTo(id: targetID) }
            }
        } else {
            pendingEditorScrollLine = controller.enterEditMode()
        }
    }

    // MARK: - Export / clipboard (menu actions)

    func save() { controller?.save() }

    func copyAsRichText() {
        guard let controller else { return }
        RichTextExporter.copyAsRichText(blocks: controller.blocks, theme: readingTheme, plainMarkdown: controller.currentText)
    }

    func exportPDF() {
        guard let controller else { return }
        let name = (currentURL?.deletingPathExtension().lastPathComponent ?? "Document") + ".pdf"
        PDFExporter.exportPDF(blocks: controller.blocks, suggestedName: name)
    }

    func printDocument() {
        guard let controller else { return }
        PDFExporter.print(blocks: controller.blocks)
    }

    // MARK: - Outline dropdown

    /// The document's flat heading outline (one entry per top-level heading),
    /// rebuilt from the live block model so it tracks live reloads.
    var outlineItems: [OutlineItem] { OutlineBuilder.build(from: controller?.blocks ?? []) }

    /// Whether the dropdown is meaningful: a document needs at least two
    /// headings to jump between. One or zero headings ⇒ button disabled.
    var hasOutline: Bool { outlineItems.count > 1 }

    /// Builds and pops up the native headings menu, anchored to the toolbar
    /// button (falling back to the window's top-leading corner). Called by both
    /// the toolbar button and ⌘1. No-op unless there's something to jump to.
    func showOutlineMenu() {
        let items = outlineItems
        guard items.count > 1 else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // A single strong target routes every item's action back to
        // `scrollToHeading`. Kept alive on the stack for the whole `popUp`
        // (which runs a nested modal loop synchronously).
        let target = OutlineMenuTarget { [weak self] id in
            self?.scrollToHeading(id, reduceMotion: reduceMotion)
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            let menuItem = NSMenuItem(title: item.title, action: #selector(OutlineMenuTarget.fire(_:)), keyEquivalent: "")
            menuItem.indentationLevel = item.depth
            menuItem.representedObject = item.id
            menuItem.target = target
            menuItem.state = item.id == currentOutlineID ? .on : .off
            menu.addItem(menuItem)
        }

        if let anchor = outlineAnchor {
            // The anchor is a plain (non-flipped) NSView behind the toolbar
            // button, so its origin is bottom-left: y just below 0 drops the
            // menu directly under the button with a hair of gap.
            let dropPoint = NSPoint(x: 0, y: anchor.isFlipped ? anchor.bounds.height + 4 : -4)
            menu.popUp(positioning: nil, at: dropPoint, in: anchor)
        } else if let content = window?.contentView {
            let y = content.isFlipped ? 8 : content.bounds.height - 8
            menu.popUp(positioning: nil, at: NSPoint(x: 16, y: y), in: content)
        }
    }

    /// Debounced current-section tracking off the reading view's top-most
    /// block. Called by `DocumentRenderer` on every scroll-position change.
    func trackOutline(topBlockID: String?) {
        outlineTrackTask?.cancel()
        outlineTrackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(70))
            guard let self, !Task.isCancelled else { return }
            guard Date() >= self.suppressOutlineTrackingUntil else { return }
            // Skip the O(n) scan while the window is being live-resized — the
            // top block barely moves and the highlight re-settles on the next
            // real scroll.
            guard !self.isLiveResizing else { return }
            self.currentOutlineID = self.nearestHeading(topBlockID: topBlockID)
        }
    }

    /// The last heading at or above the top-most visible block — the section
    /// the reader is currently inside.
    private func nearestHeading(topBlockID: String?) -> String? {
        let blocks = controller?.blocks ?? []
        let items = outlineItems
        guard let topBlockID, let topIndex = blocks.firstIndex(where: { $0.id == topBlockID }) else {
            return items.first?.id
        }
        var current: String? = items.first?.id
        for index in 0...topIndex where index < blocks.count {
            if case .heading = blocks[index].kind {
                current = blocks[index].id
            }
        }
        return current
    }

    /// The heading an outline tap just jumped to, tagged with a token so the
    /// reading view re-fires the arrival pulse even on a repeat tap of the same
    /// row. `nil` until the first outline jump.
    struct OutlineArrival: Equatable {
        var id: String
        var token: Int
    }
    private(set) var outlineArrival: OutlineArrival?
    private var outlineArrivalToken = 0

    /// Jumps the reading view to a heading picked in the outline, anchoring it
    /// to the top of the viewport. The jump is instant and exact: an animated
    /// `scrollTo` over the `LazyVStack`'s *estimated* offsets overshoots and
    /// snaps, and SwiftUI's per-frame scroll primitives are too imprecise to
    /// glide onto the anchor cleanly. Instead the landing is instant and a brief
    /// arrival pulse on the target heading carries the sense of motion (skipped
    /// under Reduce Motion, which gates only the pulse).
    func scrollToHeading(_ id: String, reduceMotion: Bool) {
        guard let controller else { return }
        deselectAll()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { controller.scrollPosition.scrollTo(id: id, anchor: .top) }
        // Move the checkmark to the jumped-to heading now, and hold off the
        // scroll tracker so it doesn't re-derive (and flicker) the same value.
        currentOutlineID = id
        suppressOutlineTrackingUntil = Date().addingTimeInterval(0.35)
        guard !reduceMotion else { return }
        outlineArrivalToken &+= 1
        outlineArrival = OutlineArrival(id: id, token: outlineArrivalToken)
    }

    // MARK: - Scroll memory

    private func saveScrollAnchor() {
        guard let controller, let url = currentURL,
              let id = controller.scrollPosition.viewID as? String else { return }
        scrollMemory[url.path] = id
        UserDefaults.standard.set(id, forKey: scrollKey(url))
    }

    private func savedAnchor(for url: URL) -> String? {
        scrollMemory[url.path] ?? UserDefaults.standard.string(forKey: scrollKey(url))
    }

    private func scrollKey(_ url: URL) -> String { "scrollAnchor:\(url.path)" }
}

/// Routes an `NSMenuItem`'s action back to a Swift closure, carrying the
/// heading id in the item's `representedObject`. One instance backs the whole
/// outline menu; it's retained for the life of the synchronous `popUp`.
@MainActor
final class OutlineMenuTarget: NSObject {
    private let handler: (String) -> Void
    init(_ handler: @escaping (String) -> Void) { self.handler = handler }

    @objc func fire(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        handler(id)
    }
}

/// GitHub-flavored heading anchor slugs, for resolving `[x](#heading)` links.
enum HeadingSlug {
    static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        var result = ""
        for scalar in lowered.unicodeScalars {
            if scalar == " " || scalar == "-" {
                result.append("-")
            } else if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
            }
            // drop everything else (punctuation) — matches GitHub
        }
        return result
    }

    /// Normalizes an incoming URL fragment for comparison against a slug.
    static func normalize(_ fragment: String) -> String {
        slug(fragment.removingPercentEncoding ?? fragment)
    }
}
