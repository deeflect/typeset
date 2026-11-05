import AppKit
import MarcoCore
import Observation
import SwiftUI
import UniformTypeIdentifiers
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
    private(set) var readingSnapshot: NativeMarkdownDocument?
    private(set) var metadataExpanded = false
    let nativeReader = NativeMarkdownReadingView.Controller()
    private var snapshotGeneration = 0
    private var snapshotTask: Task<Void, Never>?
    private var pendingFragment: String?

    /// The heading whose section currently contains the top of the viewport,
    /// tracked off the reading view's scroll position (debounced). Drives the
    /// selected row in the outline sidebar (^⌘S). `nil` until the first
    /// scroll signal or in a document with no headings.
    private(set) var currentOutlineID: String?
    private var outlineTrackTask: Task<Void, Never>?
    /// After the sidebar jumps to a heading we set `currentOutlineID`
    /// optimistically; the scroll tracker would otherwise re-derive it on its
    /// debounce and flicker. Ignore tracker updates until this instant.
    private var suppressOutlineTrackingUntil: Date = .distantPast
    /// Whether the outline sidebar is showing (^⌘S, toolbar toggle).
    var showsOutline = false
    /// Close on the moved/deleted banner; reset per document.
    var removedBannerDismissed = false

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
            if window === oldValue {
                if let window, let closeDelegate, window.delegate !== closeDelegate {
                    closeDelegate.forwardedDelegate = window.delegate
                    window.delegate = closeDelegate
                }
                return
            }
            if let oldValue, oldValue.delegate === closeDelegate {
                oldValue.delegate = closeDelegate?.forwardedDelegate
            }
            if let window {
                let proxy = WindowCloseDelegate(model: self, forwardedDelegate: window.delegate)
                closeDelegate = proxy
                window.delegate = proxy
            }
            controller?.window = window
            applyWindowIdentity()
            observeLiveResize(of: window)
        }
    }
    private var closeDelegate: WindowCloseDelegate?

    /// Keeps the window's `title` and `representedURL` pointed at the live
    /// document. The toolbar shows it via `navigationTitle`, and the
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
        snapshotGeneration += 1
        snapshotTask?.cancel()
        controller?.stop()
        hintClearTask?.cancel()
        liveResizeObservers.forEach { NotificationCenter.default.removeObserver($0) }
        liveResizeObservers.removeAll()
    }

    private func activate(_ url: URL, restoreScroll: Bool) {
        metadataExpanded = false
        removedBannerDismissed = false
        snapshotGeneration += 1
        snapshotTask?.cancel()
        readingSnapshot = nil
        controller?.stop()
        let controller = DocumentReloadController(url: url)
        controller.window = window
        controller.onInitialLoaded = { [weak self, weak controller] in
            guard let self, let controller else { return }
            if restoreScroll, let anchor = self.savedAnchor(for: url),
               controller.blocks.contains(where: { $0.id == anchor }) {
                self.nativeReader.queueJump(toBlock: anchor)
            }
            if let fragment = self.pendingFragment {
                self.pendingFragment = nil
                self.scrollToAnchor(fragment)
            }
        }
        controller.onDocumentChanged = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.buildSnapshot(for: controller)
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
    }

    func setReadingTheme(_ theme: Theme) {
        readingTheme = theme
        if let controller, !controller.isLoading { buildSnapshot(for: controller) }
    }

    private func buildSnapshot(for controller: DocumentReloadController) {
        snapshotGeneration += 1
        let generation = snapshotGeneration
        snapshotTask?.cancel()
        let source = controller.currentText
        let blocks = controller.blocks
        let theme = readingTheme
        let url = controller.url
        let expanded = metadataExpanded
        snapshotTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            guard let snapshot = try? NativeMarkdownDocument.buildCancellable(
                source: source, blocks: blocks, theme: theme, documentURL: url, metadataExpanded: expanded
            ) else { return }
            await MainActor.run { [weak self] in
                guard let self, self.snapshotGeneration == generation else { return }
                if let jump = controller.takeRequestedBlockID() { self.nativeReader.queueJump(toBlock: jump) }
                if !controller.pulsedBlockIDs.isEmpty { self.nativeReader.queuePulse(blockIDs: controller.pulsedBlockIDs) }
                self.readingSnapshot = snapshot
            }
        }
    }

    func toggleMetadata() {
        metadataExpanded.toggle()
        if let controller { buildSnapshot(for: controller) }
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
        guard controller?.prepareToLeave() ?? true else { return }
        saveScrollAnchor()
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(std)
        historyIndex = history.count - 1
        activate(std, restoreScroll: false)
    }

    /// Locate… on the moved/deleted banner: pick the file's new home.
    func locateMovedFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["md", "markdown", "mdown"].compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = currentURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        navigate(to: url)
    }

    func goBack() {
        guard canGoBack else { return }
        guard controller?.prepareToLeave() ?? true else { return }
        saveScrollAnchor()
        historyIndex -= 1
        activate(history[historyIndex], restoreScroll: true)
    }

    func goForward() {
        guard canGoForward else { return }
        guard controller?.prepareToLeave() ?? true else { return }
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
            accessHint = "Can\u{2019}t open \(url.lastPathComponent) without access to \u{201c}\(folderName)\u{201d}"
            accessHintAction = (title: "Allow Access\u{2026}", url: url)
        } else {
            accessHint = "\(url.lastPathComponent) is outside the folder you allowed"
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
            message: "Allow \(Bundle.main.displayName) to open files in \u{201c}\(folder.lastPathComponent)\u{201d}")
        guard granted != nil else { return }
        dismissAccessHint()
        navigate(to: url)
    }

    // MARK: - Anchor navigation (#heading) within the current doc

    /// Scrolls to the heading whose slugified text matches `fragment`
    /// (GitHub-style anchors). Returns true if a heading matched.
    @discardableResult
    func scrollToAnchor(_ fragment: String) -> Bool {
        guard controller != nil else { return false }
        let target = HeadingSlug.normalize(fragment)
        for item in outlineItems {
            let slug = HeadingSlug.slug(item.title)
            if slug == target {
                if readingSnapshot == nil { nativeReader.queueJump(toBlock: item.id) }
                else { nativeReader.jump(toBlock: item.id) }
                return true
            }
        }
        if let id = readingSnapshot?.footnoteBlockIDs[fragment.lowercased()] {
            nativeReader.jump(toBlock: id)
            return true
        }
        return false
    }

    func openReadingLink(_ url: URL) -> Bool {
        guard url.isFileURL || url.scheme == nil else { return false }
        let target = url.scheme == nil
            ? URL(string: url.relativeString, relativeTo: currentURL?.deletingLastPathComponent())?.absoluteURL ?? url
            : url
        var parts = URLComponents(url: target, resolvingAgainstBaseURL: false)
        let fragment = parts?.fragment
        parts?.fragment = nil
        let file = (parts?.url ?? target).standardizedFileURL
        if file == currentURL?.standardizedFileURL {
            if let fragment { _ = scrollToAnchor(fragment) }
            return true
        }
        if ["md", "markdown", "mdown"].contains(file.pathExtension.lowercased()) {
            pendingFragment = fragment
            navigate(to: file)
            if currentURL != file { pendingFragment = nil }
            return true
        }
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
            return true
        }
        return false
    }

    // MARK: - Find

    func openFind() {
        if controller?.isEditing == true { editorHandle.find(.showFindInterface) }
        else { nativeReader.showFind() }
    }

    /// Advances to the next/previous match and scrolls it into view.
    func findNext() {
        if controller?.isEditing == true { editorHandle.find(.nextMatch) }
        else { nativeReader.findNext() }
    }
    func findPrevious() {
        if controller?.isEditing == true { editorHandle.find(.previousMatch) }
        else { nativeReader.findPrevious() }
    }

    // MARK: - Edit mode (⌘E), position-preserving in both directions

    func toggleEditMode() {
        guard let controller else { return }
        if controller.isEditing {
            let caretLine = editorHandle.caretLine()
            let result = controller.exitEditMode(caretLine: caretLine)
            guard result.allowed else { return }
            if let targetID = result.anchor {
                nativeReader.jump(toBlock: targetID)
            }
        } else {
            pendingEditorScrollLine = controller.enterEditMode()
        }
    }

    // MARK: - Export / clipboard (menu actions)

    func save() { controller?.save() }

    @discardableResult
    func saveAs(to destination: URL) -> Bool {
        guard let controller, controller.isEditing else { return false }
        let destination = destination.standardizedFileURL
        guard destination != currentURL else {
            controller.saveError = "Choose a different file to save to"
            return false
        }
        do {
            try Data(controller.editedText.utf8).write(to: destination, options: .atomic)
            history[historyIndex] = destination
            activate(destination, restoreScroll: false)
            return true
        } catch {
            controller.saveError = "Couldn\u{2019}t save to \(destination.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    var canSave: Bool { controller?.isEditing == true && controller?.conflictState == .dirty }
    var canFind: Bool {
        guard let controller else { return false }
        return controller.isEditing || (!controller.isLoading && readingSnapshot != nil)
    }
    func prepareToClose() -> Bool { controller?.prepareToLeave() ?? true }

    func copyAsRichText(pasteboard: NSPasteboard = .general) {
        guard let controller else { return }
        RichTextExporter.copyLiveSource(controller.currentText, theme: readingTheme, url: controller.url, pasteboard: pasteboard)
    }

    func exportPDF() {
        guard let controller else { return }
        let name = (currentURL?.deletingPathExtension().lastPathComponent ?? "Document") + ".pdf"
        PDFExporter.exportPDF(source: controller.currentText, url: controller.url, suggestedName: name)
    }

    func printDocument() {
        guard let controller else { return }
        PDFExporter.print(source: controller.currentText, url: controller.url)
    }

    // MARK: - Outline sidebar

    /// The document's flat heading outline (one entry per top-level heading),
    /// rebuilt from the live block model so it tracks live reloads.
    var outlineItems: [OutlineItem] { OutlineBuilder.build(from: controller?.blocks ?? []) }

    /// Debounced current-section tracking off the reading view's top-most
    /// block. Called by the native reader as its visible block changes.
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

    /// Jumps to a heading and briefly pulses its text as arrival feedback.
    func scrollToHeading(_ id: String, reduceMotion: Bool) {
        guard controller != nil else { return }
        nativeReader.jump(toBlock: id)
        // Move the checkmark to the jumped-to heading now, and hold off the
        // scroll tracker so it doesn't re-derive (and flicker) the same value.
        currentOutlineID = id
        suppressOutlineTrackingUntil = Date().addingTimeInterval(0.35)
        if !reduceMotion { nativeReader.pulse(blockIDs: [id]) }
    }

    // MARK: - Scroll memory

    private func saveScrollAnchor() {
        guard let controller, let url = currentURL,
              let id = controller.visibleBlockID else { return }
        scrollMemory[url.path] = id
        UserDefaults.standard.set(id, forKey: scrollKey(url))
    }

    private func savedAnchor(for url: URL) -> String? {
        scrollMemory[url.path] ?? UserDefaults.standard.string(forKey: scrollKey(url))
    }

    private func scrollKey(_ url: URL) -> String { "scrollAnchor:\(url.path)" }
}

/// Intercepts close without dropping SwiftUI's existing window delegate.
@MainActor
private final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    weak var model: WindowModel?
    nonisolated(unsafe) weak var forwardedDelegate: NSWindowDelegate?

    init(model: WindowModel, forwardedDelegate: NSWindowDelegate?) {
        self.model = model
        self.forwardedDelegate = forwardedDelegate
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model?.prepareToClose() ?? true else { return false }
        return forwardedDelegate?.windowShouldClose?(sender) ?? true
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || forwardedDelegate?.responds(to: aSelector) == true
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        forwardedDelegate?.responds(to: aSelector) == true ? forwardedDelegate : super.forwardingTarget(for: aSelector)
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
