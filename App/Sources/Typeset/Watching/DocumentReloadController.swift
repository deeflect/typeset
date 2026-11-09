import AppKit
import Foundation
import TypesetCore
import Observation
import os
import TypesetRendering

/// Owns everything about keeping a `DocumentWindow` in sync with its file
/// on disk: the initial parse, the `FileWatcher`, the off-main
/// reparse+diff pipeline, scroll anchoring, the change-pulse set, and the
/// per-window follow-mode toggle.
@Observable
@MainActor
final class DocumentReloadController {
    let url: URL

    private(set) var blocks: [Block] = []
    private(set) var loadError: String?
    private(set) var isLoading = true
    /// True once the file has been missing for longer than the watcher's
    /// grace period (PLAN §4: survive delete/recreate without flashing
    /// this for the common "delete then immediately recreate" save
    /// pattern — only a persistent absence surfaces here).
    private(set) var isFileRemoved = false
    /// Ids of blocks that should show the one-time change-pulse tint right
    /// now. Populated only by watcher-driven reloads, never by the initial
    /// load or a text-scale change.
    private(set) var pulsedBlockIDs: Set<String> = []
    /// Flips true the first time this document changes on disk under us.
    /// Gates the contextual reveal of the follow-mode toolbar toggle, which
    /// is meaningless until a file is actually being rewritten live.
    private(set) var hasExternalChanges = false
    /// When the file last changed on disk under us; drives "Updated just now".
    private(set) var lastExternalChange: Date?
    /// "2 added, 1 changed" for the reload toast; `changeSummaryID` bumps per reload.
    private(set) var changeSummary = ""
    private(set) var changeSummaryID = 0

    // MARK: - M3: source edit mode, save, conflict banner

    /// Whether the window is currently showing the source editor (⌘E)
    /// rather than the reading view.
    private(set) var isEditing = false
    /// The editor's live buffer contents. Bound two-way to the `NSTextView`
    /// wrapper; starts each edit session as a copy of `lastText`.
    var editedText: String = ""
    /// Clean / dirty / conflict-pending, per `EditConflictMachine` (PLAN
    /// §4). Drives both the dirty-dot (`window.isDocumentEdited`) and the
    /// non-modal conflict banner.
    private(set) var conflictState: EditSessionState = .clean
    /// Set when `save()` fails (no write access, volume gone, etc.) so the
    /// window can show a non-modal banner with a Save As… fallback instead
    /// of losing the edit silently.
    var saveError: String?
    /// Weak ref to the hosting window, set once by `DocumentWindow` via a
    /// small `NSViewRepresentable` accessor, so dirty state can drive the
    /// standard `isDocumentEdited` title-bar dot.
    weak var window: NSWindow? {
        didSet { window?.isDocumentEdited = conflictState != .clean }
    }

    /// Toolbar toggle; auto-scrolls to the newest changed block after each
    /// reload when on. Persisted per-window (per file path), off by
    /// default.
    var followModeEnabled: Bool {
        didSet {
            guard followModeEnabled != oldValue else { return }
            RecentPathDefaults.set(followModeEnabled, for: url.path, in: Self.followModeKey)
        }
    }

    var visibleBlockID: String?
    private(set) var requestedBlockID: String?
    func takeRequestedBlockID() -> String? {
        defer { requestedBlockID = nil }
        return requestedBlockID
    }

    private var lastText: String = ""
    private var diskSnapshot: DocumentFileIO.Snapshot?
    private var reloadGeneration = 0
    private var editRevision = 0
    private var approvedDiskSnapshot: DocumentFileIO.Snapshot?
    private var isStopped = false
    /// The current Markdown source: the live edit buffer while editing,
    /// otherwise the last text read from disk. Used by Copy as Rich
    /// Text's plain-Markdown pasteboard fallback.
    var currentText: String { isEditing ? editedText : lastText }
    var hasUTF8BOM: Bool { diskSnapshot?.data.starts(with: [0xEF, 0xBB, 0xBF]) == true }
    private var watcher: FileWatcher?
    private var initialTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private let signposter = OSSignposter(subsystem: "com.deeflect.typeset", category: "LiveReload")
    private var pulseClearTask: Task<Void, Never>?
    /// Whether this controller holds an active security-scope grant on
    /// `url`. Held for the controller's whole lifetime (not just around
    /// each read) because `FileWatcher` keeps its own long-lived open file
    /// descriptor on `url` for kqueue monitoring — that `open()` needs the
    /// scope active at attach time, same as any other file access to a
    /// security-scoped URL (e.g. one obtained from an Open panel).
    private var isAccessingSecurityScope = false
    /// A scope of our own, resolved from a fresh bookmark, so Recents (or
    /// anything else) stopping the scope we were handed can't cut this open
    /// document off while its window lives.
    private var ownScope: URL?

    private static let followModeKey = "followModeByPath"

    /// Debug/verification hook (mirrors `SnapshotRunner`'s `TYPESET_SNAPSHOT`
    /// pattern): fires after each watcher-driven reload is applied, with
    /// the measured read+parse+diff+apply latency. Used by
    /// `ReloadBenchRunner` (`TYPESET_RELOAD_BENCH`) to report real numbers
    /// end-to-end without needing a visible window. `nil` in normal app
    /// use.
    var onReloadApplied: ((ReloadReport) -> Void)?
    var onInitialLoaded: (() -> Void)?
    var onDocumentChanged: (() -> Void)?
    var onReloadReady: (() -> Void)?

    init(url: URL) {
        self.url = url
        self.followModeEnabled = RecentPathDefaults.value(for: url.path, in: Self.followModeKey) as? Bool ?? false
    }

    /// Starts watching and parses the initial document off the main actor.
    func start() {
        isStopped = false
        isAccessingSecurityScope = url.startAccessingSecurityScopedResource()
        if ownScope == nil, let bookmark = SecurityScopedBookmark.make(url),
           case .available(let scoped, _) = SecurityScopedBookmark.resolve(bookmark, path: url.path),
           scoped.startAccessingSecurityScopedResource() {
            ownScope = scoped
        }
        FolderAccessStore.shared.noteDocumentOpened(url)
        let watcher = FileWatcher(url: url)
        watcher.onReload = { [weak self] in
            Task { @MainActor in self?.handleExternalChange() }
        }
        watcher.onRemovedChanged = { [weak self] removed in
            Task { @MainActor [weak self] in
                guard self?.isStopped == false else { return }
                self?.isFileRemoved = removed
            }
        }
        self.watcher = watcher
        watcher.whenReady { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped else { return }
                self.loadInitial()
            }
        }
    }

    /// Clean up only after a transition has been accepted.
    func stop() {
        isStopped = true
        reloadGeneration += 1
        initialTask?.cancel()
        reloadTask?.cancel()
        watcher = nil
        pulseClearTask?.cancel()
        FolderAccessStore.shared.noteDocumentClosed(url)
        if isAccessingSecurityScope {
            url.stopAccessingSecurityScopedResource()
            isAccessingSecurityScope = false
        }
        ownScope?.stopAccessingSecurityScopedResource()
        ownScope = nil
    }

    private func loadInitial() {
        initialTask?.cancel()
        isLoading = true
        reloadGeneration += 1
        let generation = reloadGeneration
        let fileURL = url
        initialTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            let result = Result { () -> (DocumentFileIO.Snapshot, [Block]) in
                let didAccess = fileURL.startAccessingSecurityScopedResource()
                defer { if didAccess { fileURL.stopAccessingSecurityScopedResource() } }
                let snapshot = try DocumentFileIO.read(fileURL)
                try Task.checkCancellation()
                return (snapshot, MarkdownParser.parse(snapshot.text, mdx: MarkdownParser.isMDX(fileURL)))
            }
            await MainActor.run { [weak self] in
                guard let self, !self.isStopped, self.reloadGeneration == generation else { return }
                self.isLoading = false
                switch result {
                case .success(let (snapshot, blocks)):
                    self.diskSnapshot = snapshot
                    self.lastText = snapshot.text
                    self.blocks = blocks
                    self.loadError = nil
                case .failure(let error):
                    self.loadError = "Couldn\u{2019}t open \(fileURL.lastPathComponent): \(error.localizedDescription)"
                }
                self.onInitialLoaded?()
                if self.loadError == nil { self.onDocumentChanged?() }
            }
        }
    }

    // MARK: - Reload pipeline

    /// Watcher-driven change, routed through the M3 conflict rule (PLAN
    /// §4) when edit mode is open: clean buffer → reload silently (falls
    /// through to the same pipeline as the non-editing case); dirty buffer
    /// → surface the non-modal "Keep mine / Take theirs" banner and leave
    /// the buffer untouched until the user decides. Never a modal dialog.
    private func handleExternalChange() {
        guard !isStopped else { return }
        if isLoading { loadInitial(); return }
        if loadError != nil { loadInitial(); return }
        performReload(external: true)
    }

    /// `external`: watcher-driven, so bytes identical to `diskSnapshot` (a
    /// sibling file changed, an echo) are ignored rather than surfaced as
    /// "Updated just now". The read always happens off the main actor; a
    /// dirty buffer turns a real change into the conflict banner on return.
    private func performReload(external: Bool = false) {
        reloadTask?.cancel()
        reloadGeneration += 1
        let generation = reloadGeneration
        let revision = editRevision
        let oldBlocks = blocks
        let oldText = lastText
        let fileURL = url

        let signpostID = signposter.makeSignpostID()
        let interval = signposter.beginInterval("liveReload", id: signpostID)
        let startTime = DispatchTime.now()

        reloadTask = Task.detached(priority: .userInitiated) { [signposter] in
            let result = computeReload(url: fileURL, oldText: oldText, oldBlocks: oldBlocks)
            guard let result else {
                await MainActor.run { signposter.endInterval("liveReload", interval) }
                return
            }
            await MainActor.run { [weak self] in
                signposter.endInterval("liveReload", interval)
                self?.onReloadReady?()
                guard let self, !self.isStopped, self.reloadGeneration == generation else { return }
                if external {
                    guard result.snapshot != self.diskSnapshot else { return }
                    self.hasExternalChanges = true
                    self.lastExternalChange = Date()
                }
                if self.isEditing && (self.editRevision != revision || self.conflictState != .clean) {
                    if self.conflictState == .dirty {
                        self.conflictState = .conflictPending
                    } else if self.conflictState == .clean {
                        self.performReload(external: external)
                    }
                    return
                }
                self.apply(result, startTime: startTime)
            }
        }
    }

    private func apply(_ result: ReloadResult, startTime: DispatchTime) {
        diskSnapshot = result.snapshot
        if isEditing, conflictState == .clean { editedText = result.newText }
        let changed = !result.newText.utf8.elementsEqual(lastText.utf8)
        lastText = result.newText
        guard changed else { return }

        let currentAnchorID = visibleBlockID
        let anchorIndex = currentAnchorID.flatMap { id in blocks.firstIndex { $0.id == id } } ?? 0
        let anchorTarget = ScrollAnchor.selectAnchor(
            oldBlocks: blocks, changes: result.changes, anchorIndex: anchorIndex)

        var changedIDs: Set<String> = []
        var firstChangedID: String?
        var added = 0, edited = 0, removed = 0
        for change in result.changes {
            switch change {
            case .inserted(let block):
                added += 1
                changedIDs.insert(block.id)
                if firstChangedID == nil { firstChangedID = block.id }
            case .reloaded(_, let new):
                edited += 1
                changedIDs.insert(new.id)
                if firstChangedID == nil { firstChangedID = new.id }
            case .deleted:
                removed += 1
            case .unchanged:
                continue
            }
        }
        // Most edits arrive as an adjacent delete + insert; count those pairs as changes.
        let paired = min(added, removed)
        added -= paired; removed -= paired; edited += paired
        let parts = [(added, "added"), (edited, "changed"), (removed, "removed")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        if !parts.isEmpty {
            changeSummary = parts.joined(separator: ", ")
            changeSummaryID &+= 1
        }

        if !changedIDs.isEmpty {
            pulsedBlockIDs.formUnion(changedIDs)
        }
        blocks = result.newBlocks

        requestedBlockID = followModeEnabled ? (firstChangedID ?? anchorTarget) : anchorTarget
        onDocumentChanged?()

        if !changedIDs.isEmpty {
            schedulePulseClear(changedIDs)
        }

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000
        onReloadApplied?(ReloadReport(blockCount: blocks.count, changedCount: changedIDs.count, elapsedMilliseconds: elapsedMs))
    }

    /// Pulse is a one-time ~800ms whisper (PLAN §6) — drop the ids back out
    /// of `pulsedBlockIDs` after it's had time to play, so a later reload
    /// that happens to reuse the same id (rare — same content again) can
    /// pulse again from a clean slate.
    private func schedulePulseClear(_ ids: Set<String>) {
        pulseClearTask?.cancel()
        pulseClearTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.pulsedBlockIDs.subtract(ids)
        }
    }

    // MARK: - M3: edit mode

    /// Enters source edit mode (⌘E). Returns the absolute line (in
    /// `editedText`, including any frontmatter) that the caller should
    /// scroll the editor to, so the block that was at the top of the
    /// reading viewport stays visible at the top of the editor — `nil` if
    /// there's no scroll anchor yet (top of document is fine).
    func enterEditMode() -> Int? {
        guard !isEditing, !isLoading, loadError == nil else { return nil }
        editedText = lastText
        isEditing = true
        conflictState = .clean
        window?.isDocumentEdited = false

        guard let anchorID = visibleBlockID,
              let block = blocks.first(where: { $0.id == anchorID }),
              let bodyLine = BlockPosition.startLine(of: block)
        else { return nil }
        return bodyLine + MarkdownParser.bodyLineOffset(in: editedText)
    }

    /// Exits source edit mode (⌘E back to reading, or a successful save
    /// that also leaves edit mode). `caretLine` is the absolute line (in
    /// `editedText`) the caret was on, used to anchor the reading view's
    /// scroll to the block containing it. Autosaves first if dirty
    /// (PLAN §3: "no unsaved changes modal for a simple viewer") — silent
    /// save on the happy path; a failure surfaces via `saveError` and
    /// keeps the buffer/editing state exactly as `save()` left it, so
    /// nothing is lost.
    @discardableResult
    func exitEditMode(caretLine: Int?) -> (allowed: Bool, anchor: String?) {
        guard prepareToLeave() else { return (false, nil) }
        isEditing = false

        guard let caretLine else { return (true, nil) }
        let bodyLine = caretLine - MarkdownParser.bodyLineOffset(in: editedText)
        guard let index = BlockPosition.blockIndex(forLine: bodyLine, in: blocks) else { return (true, nil) }
        return (true, blocks[index].id)
    }

    /// Notifies the controller that the editor's buffer text changed,
    /// updating dirty state (and the window's `isDocumentEdited` dot)
    /// accordingly. Cheap to call on every keystroke: the conflict machine
    /// only actually transitions on the clean↔dirty edge.
    func noteEditedTextChanged(_ text: String) {
        guard isEditing else { return }
        // Byte comparisons (not String ==, which is canonical-equivalence),
        // without copying the buffer into `Data` on every keystroke.
        if !text.utf8.elementsEqual(editedText.utf8) {
            editRevision += 1
            approvedDiskSnapshot = nil
        }
        editedText = text
        let isDirtyNow = !text.utf8.elementsEqual(lastText.utf8)
        switch (conflictState, isDirtyNow) {
        case (.clean, true):
            conflictState = EditConflictMachine.transition(state: .clean, event: .bufferEdited).state
        case (.dirty, false):
            conflictState = EditConflictMachine.transition(state: .dirty, event: .bufferSettled).state
        default:
            break
        }
        window?.isDocumentEdited = conflictState != .clean
    }

    /// ⌘S: atomically writes `editedText` to disk, suppressing the
    /// watcher's echo of this save via `expectOwnWrite` (M2 hook) so it
    /// doesn't bounce back as a reload. On success, settles the buffer to
    /// clean and reparses so the reading view is ready the moment ⌘E goes
    /// back. On failure, leaves the buffer dirty and sets `saveError` for
    /// the window's non-modal banner (Save As… fallback), per PLAN §3.
    @discardableResult
    func save() -> Bool {
        guard isEditing, conflictState != .clean else { return false }
        guard conflictState != .conflictPending else { return false }
        do {
            let current = try DocumentFileIO.read(url)
            guard let expected = approvedDiskSnapshot ?? diskSnapshot else { return false }
            if current != expected {
                conflictState = .conflictPending
                return false
            }
            let saved = try DocumentFileIO.replace(url, text: editedText, expected: expected)
            watcher?.expectOwnWrite(contents: saved.data)
            reloadGeneration += 1
            diskSnapshot = saved
            lastText = editedText
            blocks = MarkdownParser.parse(editedText, mdx: MarkdownParser.isMDX(url))
            onDocumentChanged?()
            conflictState = EditConflictMachine.transition(state: conflictState, event: .bufferSettled).state
            window?.isDocumentEdited = false
            saveError = nil
            approvedDiskSnapshot = nil
            return true
        } catch {
            saveError = "Couldn\u{2019}t save \(url.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    var hasUnsavedEdits: Bool { isEditing && conflictState != .clean }

    /// Used before navigation, closing, and app termination.
    func prepareToLeave() -> Bool {
        guard hasUnsavedEdits else { return true }
        return save()
    }

    /// "Discard Changes" when a close/quit can't save: drop the buffer back
    /// to the last text read from disk.
    func discardEdits() {
        guard isEditing else { return }
        editedText = lastText
        editRevision += 1
        approvedDiskSnapshot = nil
        saveError = nil
        conflictState = .clean
        window?.isDocumentEdited = false
    }

    /// "Keep mine" at the conflict banner: dismiss it, keep the buffer
    /// as-is — the next ⌘S overwrites disk.
    func resolveConflictKeepMine() {
        guard conflictState == .conflictPending else { return }
        guard let snapshot = try? DocumentFileIO.read(url) else { return }
        approvedDiskSnapshot = snapshot
        conflictState = EditConflictMachine.transition(state: conflictState, event: .keepMine).state
    }

    /// "Take theirs" at the conflict banner: reload from disk through the
    /// normal position-preserving path, discarding the in-progress edits.
    func resolveConflictTakeTheirs() {
        guard conflictState == .conflictPending else { return }
        approvedDiskSnapshot = nil
        reloadGeneration += 1
        editRevision += 1
        conflictState = EditConflictMachine.transition(state: conflictState, event: .takeTheirs).state
        performReload()
    }

    // MARK: - M3: reading-view checkbox write-back

    /// PLAN §5: flips a task checkbox's exact character in the file and
    /// writes it back atomically, without entering edit mode. Verifies
    /// against the current in-memory text first (`CheckboxWriteBack.flip`'s
    /// guard); if that fails — the file changed under us since the click
    /// was registered — falls back to a normal reload instead of writing
    /// blind, per the M3 spec.
    func toggleCheckbox(blockStartLine: Int, itemLineOffset: Int, checked: Bool) {
        guard !isEditing, !isLoading else { return }
        guard let current = try? DocumentFileIO.read(url), current == diskSnapshot else {
            handleExternalChange()
            return
        }
        guard let newText = CheckboxWriteBack.flip(
            fileText: lastText, blockStartLine: blockStartLine, itemLineOffset: itemLineOffset, checked: checked
        ) else {
            handleExternalChange()
            return
        }

        do {
            let saved = try DocumentFileIO.replace(url, text: newText, expected: current)
            watcher?.expectOwnWrite(contents: saved.data)
            reloadGeneration += 1
            diskSnapshot = saved
            blocks = MarkdownParser.parse(newText, mdx: MarkdownParser.isMDX(url))
            lastText = newText
            onDocumentChanged?()
        } catch {
            // Write failed (permissions/volume gone); the in-memory model
            // is untouched, so the UI simply doesn't reflect the click —
            // consistent with "don't write blind" for the failure case too.
        }
    }
}

/// Measured latency + shape of one applied reload, for verification/bench
/// use only (see `onReloadApplied`).
struct ReloadReport: Sendable {
    let blockCount: Int
    let changedCount: Int
    let elapsedMilliseconds: Double
}

/// The result of one off-main reparse+diff pass. Sendable so it can cross
/// from `Task.detached` back to the main actor without copying concerns —
/// `Block`/`BlockChange` are themselves `Sendable` value types.
private struct ReloadResult: Sendable {
    let snapshot: DocumentFileIO.Snapshot
    var newText: String { snapshot.text }
    let newBlocks: [Block]
    let changes: [BlockChange]
}

/// Free function (not a method) so it carries no implicit `self`/actor
/// isolation into the `Task.detached` closure that calls it — only value
/// types cross that boundary.
private nonisolated func computeReload(url: URL, oldText: String, oldBlocks: [Block]) -> ReloadResult? {
    guard !Task.isCancelled else { return nil }
    let didAccess = url.startAccessingSecurityScopedResource()
    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
    guard let snapshot = try? DocumentFileIO.read(url) else {
        // Read races with an in-flight delete/replace are expected and
        // harmless here: the watcher's own removed-state tracking (not
        // this pipeline) is what surfaces that to the UI. Just skip this
        // reload attempt; the next settled write will trigger another.
        return nil
    }
    guard !Task.isCancelled else { return nil }
    let newText = snapshot.text
    let newBlocks: [Block] = newText.isEmpty
        ? []
        : MarkdownParser.isMDX(url)
            // Incremental reparse is block-local; MDX containers span blocks, so reparse whole.
            ? MarkdownParser.parse(newText, mdx: true)
            : MarkdownParser.reparseIncremental(oldText: oldText, newText: newText, oldBlocks: oldBlocks)
    let changes = BlockDiffer.diff(old: oldBlocks, new: newBlocks)
    return ReloadResult(snapshot: snapshot, newBlocks: newBlocks, changes: changes)
}
