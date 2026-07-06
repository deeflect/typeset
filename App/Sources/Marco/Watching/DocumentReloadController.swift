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

    func stop() {
        watcher = nil
        pulseClearTask?.cancel()
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

    private func handleExternalChange() {
        guard loadError == nil else { return }
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

        if let anchorTarget {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollPosition.scrollTo(id: anchorTarget)
            }
        }

        if followModeEnabled, let firstChangedID {
            withAnimation(.easeInOut(duration: 0.35)) {
                scrollPosition.scrollTo(id: firstChangedID)
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
