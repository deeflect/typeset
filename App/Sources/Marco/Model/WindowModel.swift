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

    /// Outline sidebar visibility (⌘1 / toolbar). Collapsed by default so the
    /// J1 "just open it" reading view stays minimal; per-window because each
    /// `WindowModel` instance is per-window.
    var sidebarVisible = false

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
        didSet { controller?.window = window }
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
    }

    private func activate(_ url: URL, restoreScroll: Bool) {
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

    // MARK: - Sidebar

    func toggleSidebar() { sidebarVisible.toggle() }

    /// Smooth-scrolls the reading view to a heading picked in the outline;
    /// jumps instantly under Reduce Motion.
    func scrollToHeading(_ id: String, reduceMotion: Bool) {
        guard let controller else { return }
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { controller.scrollPosition.scrollTo(id: id) }
        } else {
            withAnimation(.easeInOut(duration: 0.32)) { controller.scrollPosition.scrollTo(id: id) }
        }
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
