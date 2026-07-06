import AppKit
import Foundation
import MarcoCore
import Observation
import SwiftUI
import os

/// Owns everything about keeping a `DocumentWindow` in sync with its file
/// on disk: the initial parse, the `FileWatcher`, the off-main
/// reparse+diff pipeline, scroll anchoring, the change-pulse set, and the
/// per-window follow-mode toggle. `DocumentWindow`/`DocumentRenderer` just
/// read this via `@Bindable`.
@Observable
@MainActor
final class DocumentReloadController {
    let url: URL

    private(set) var blocks: [Block] = []
    private(set) var loadError: String?
    /// True once the file has been missing for longer than the watcher's
    /// grace period (PLAN §4: survive delete/recreate without flashing
    /// this for the common "delete then immediately recreate" save
    /// pattern — only a persistent absence surfaces here).
    private(set) var isFileRemoved = false
    /// Ids of blocks that should show the one-time change-pulse tint right
    /// now. Populated only by watcher-driven reloads, never by the initial
    /// load or a text-scale change.
    private(set) var pulsedBlockIDs: Set<String> = []

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
            UserDefaults.standard.set(followModeEnabled, forKey: followModeDefaultsKey)
        }
    }

    /// Bound to `DocumentRenderer`'s `ScrollView` via `.scrollPosition($_)`
    /// so this controller can both read "what's on screen right now"
    /// (for anchor selection) and drive scroll (to hold the anchor steady,
    /// or to follow the newest change).
    var scrollPosition = ScrollPosition(idType: String.self)

    private var lastText: String = ""
    /// The current Markdown source: the live edit buffer while editing,
    /// otherwise the last text read from disk. Used by Copy as Rich
    /// Text's plain-Markdown pasteboard fallback.
    var currentText: String { isEditing ? editedText : lastText }
    private var watcher: FileWatcher?
    private let signposter = OSSignposter(subsystem: "com.dee.marco.draft", category: "LiveReload")
    private var pulseClearTask: Task<Void, Never>?
    /// Whether this controller holds an active security-scope grant on
    /// `url`. Held for the controller's whole lifetime (not just around
    /// each read) because `FileWatcher` keeps its own long-lived open file
    /// descriptor on `url` for kqueue monitoring — that `open()` needs the
    /// scope active at attach time, same as any other file access to a
    /// security-scoped URL (e.g. one obtained from an Open panel).
    private var isAccessingSecurityScope = false

    private var followModeDefaultsKey: String { "followMode:\(url.path)" }

    /// Debug/verification hook (mirrors `SnapshotRunner`'s `MARCO_SNAPSHOT`
    /// pattern): fires after each watcher-driven reload is applied, with
    /// the measured read+parse+diff+apply latency. Used by
    /// `ReloadBenchRunner` (`MARCO_RELOAD_BENCH`) to report real numbers
    /// end-to-end without needing a visible window. `nil` in normal app
    /// use.
    var onReloadApplied: ((ReloadReport) -> Void)?

    init(url: URL) {
        self.url = url
        self.followModeEnabled = UserDefaults.standard.bool(forKey: "followMode:\(url.path)")
    }

    /// Loads the file synchronously (cheap enough for typical files; large
    /// files are a pre-existing M1 concern, not new here) and starts
    /// watching for further changes. Call once per window/url.
    func start() {
        isAccessingSecurityScope = url.startAccessingSecurityScopedResource()
        FolderAccessStore.shared.noteDocumentOpened(url)
        loadInitial()
        let watcher = FileWatcher(url: url)
        watcher.onReload = { [weak self] in
            Task { @MainActor in self?.handleExternalChange() }
        }
        watcher.onRemovedChanged = { [weak self] removed in
            Task { @MainActor in self?.isFileRemoved = removed }
        }
        self.watcher = watcher
    }

    /// Called on window close / app termination. PLAN §3: no "unsaved
    /// changes" modal for a simple viewer — save silently if we have write
    /// access (failure is unobservable at this point since the window is
    /// going away regardless; a real write failure would already have
    /// surfaced via `saveError` from an earlier ⌘S/⌘E attempt).
    func stop() {
        if isEditing, conflictState != .clean {
            save()
        }
        watcher = nil
        pulseClearTask?.cancel()
        FolderAccessStore.shared.noteDocumentClosed(url)
        if isAccessingSecurityScope {
            url.stopAccessingSecurityScopedResource()
            isAccessingSecurityScope = false
        }
    }

    private func loadInitial() {
        do {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            blocks = MarkdownParser.parse(text)
            lastText = text
            loadError = nil
        } catch {
            loadError = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: - Reload pipeline

    /// Watcher-driven change, routed through the M3 conflict rule (PLAN
    /// §4) when edit mode is open: clean buffer → reload silently (falls
    /// through to the same pipeline as the non-editing case); dirty buffer
    /// → surface the non-modal "Keep mine / Take theirs" banner and leave
    /// the buffer untouched until the user decides. Never a modal dialog.
    private func handleExternalChange() {
        guard loadError == nil else { return }
        if isEditing {
            let (newState, action) = EditConflictMachine.transition(state: conflictState, event: .externalChange)
            conflictState = newState
            if action == .showConflictBanner {
                return
            }
            // .silentReload (or a no-op) falls through to the normal
            // reload pipeline below, keeping the editor buffer in sync.
        }
        performReload()
    }

    private func performReload() {
        let oldBlocks = blocks
        let oldText = lastText
        let fileURL = url

        let signpostID = signposter.makeSignpostID()
        let interval = signposter.beginInterval("liveReload", id: signpostID)
        let startTime = DispatchTime.now()

        Task.detached(priority: .userInitiated) { [signposter] in
            let result = computeReload(url: fileURL, oldText: oldText, oldBlocks: oldBlocks)
            guard let result else {
                await MainActor.run { signposter.endInterval("liveReload", interval) }
                return
            }
            await MainActor.run { [weak self] in
                signposter.endInterval("liveReload", interval)
                self?.apply(result, startTime: startTime)
            }
        }
    }

    private func apply(_ result: ReloadResult, startTime: DispatchTime) {
        guard result.newText != lastText else { return }

        let currentAnchorID = scrollPosition.viewID as? String
        let anchorIndex = currentAnchorID.flatMap { id in blocks.firstIndex { $0.id == id } } ?? 0
        let anchorTarget = ScrollAnchor.selectAnchor(
            oldBlocks: blocks, changes: result.changes, anchorIndex: anchorIndex)

        var changedIDs: Set<String> = []
        var firstChangedID: String?
        for change in result.changes {
            switch change {
            case .inserted(let block):
                changedIDs.insert(block.id)
                if firstChangedID == nil { firstChangedID = block.id }
            case .reloaded(_, let new):
                changedIDs.insert(new.id)
                if firstChangedID == nil { firstChangedID = new.id }
            case .unchanged, .deleted:
                continue
            }
        }

        if !changedIDs.isEmpty {
            pulsedBlockIDs.formUnion(changedIDs)
        }
        blocks = result.newBlocks
        lastText = result.newText
        if isEditing {
            // Only reachable here when the conflict machine decided
            // `.silentReload` (clean buffer) — a dirty buffer short-circuits
            // in `handleExternalChange` before ever reaching this pipeline.
            editedText = result.newText
        }

        if let anchorTarget {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollPosition.scrollTo(id: anchorTarget)
            }
        }

        if followModeEnabled, let firstChangedID {
            // Follow mode auto-scrolls to the newest change. Honor Reduce
            // Motion (no @Environment here — this is a controller, not a
            // view — so read the AppKit accessibility flag directly).
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { scrollPosition.scrollTo(id: firstChangedID) }
            } else {
                withAnimation(.easeInOut(duration: 0.35)) {
                    scrollPosition.scrollTo(id: firstChangedID)
                }
            }
        }

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
        editedText = lastText
        isEditing = true
        conflictState = .clean
        window?.isDocumentEdited = false

        guard let anchorID = scrollPosition.viewID as? String,
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
    func exitEditMode(caretLine: Int?) -> String? {
        if conflictState != .clean {
            save()
        }
        isEditing = false

        guard let caretLine else { return nil }
        let bodyLine = caretLine - MarkdownParser.bodyLineOffset(in: editedText)
        guard let index = BlockPosition.blockIndex(forLine: bodyLine, in: blocks) else { return nil }
        return blocks[index].id
    }

    /// Notifies the controller that the editor's buffer text changed,
    /// updating dirty state (and the window's `isDocumentEdited` dot)
    /// accordingly. Cheap to call on every keystroke: the conflict machine
    /// only actually transitions on the clean↔dirty edge.
    func noteEditedTextChanged(_ text: String) {
        editedText = text
        let isDirtyNow = text != lastText
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
    func save() {
        watcher?.expectOwnWrite()
        do {
            try Data(editedText.utf8).write(to: url, options: .atomic)
            lastText = editedText
            blocks = MarkdownParser.parse(editedText)
            conflictState = EditConflictMachine.transition(state: conflictState, event: .bufferSettled).state
            window?.isDocumentEdited = false
            saveError = nil
        } catch {
            saveError = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// "Keep mine" at the conflict banner: dismiss it, keep the buffer
    /// as-is — the next ⌘S overwrites disk.
    func resolveConflictKeepMine() {
        conflictState = EditConflictMachine.transition(state: conflictState, event: .keepMine).state
    }

    /// "Take theirs" at the conflict banner: reload from disk through the
    /// normal position-preserving path, discarding the in-progress edits.
    func resolveConflictTakeTheirs() {
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
        guard !isEditing else { return }
        guard let newText = CheckboxWriteBack.flip(
            fileText: lastText, blockStartLine: blockStartLine, itemLineOffset: itemLineOffset, checked: checked
        ) else {
            handleExternalChange()
            return
        }

        watcher?.expectOwnWrite()
        do {
            try Data(newText.utf8).write(to: url, options: .atomic)
            blocks = MarkdownParser.parse(newText)
            lastText = newText
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
    let newText: String
    let newBlocks: [Block]
    let changes: [BlockChange]
}

/// Free function (not a method) so it carries no implicit `self`/actor
/// isolation into the `Task.detached` closure that calls it — only value
/// types cross that boundary.
private nonisolated func computeReload(url: URL, oldText: String, oldBlocks: [Block]) -> ReloadResult? {
    let didAccess = url.startAccessingSecurityScopedResource()
    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
    guard let newText = try? String(contentsOf: url, encoding: .utf8) else {
        // Read races with an in-flight delete/replace are expected and
        // harmless here: the watcher's own removed-state tracking (not
        // this pipeline) is what surfaces that to the UI. Just skip this
        // reload attempt; the next settled write will trigger another.
        return nil
    }
    let newBlocks: [Block] = newText.isEmpty
        ? []
        : MarkdownParser.reparseIncremental(oldText: oldText, newText: newText, oldBlocks: oldBlocks)
    let changes = BlockDiffer.diff(old: oldBlocks, new: newBlocks)
    return ReloadResult(newText: newText, newBlocks: newBlocks, changes: changes)
}
