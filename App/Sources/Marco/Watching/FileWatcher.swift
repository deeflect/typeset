import Foundation
import os

/// Watches a single Markdown file on disk and calls back (debounced) when
/// its contents may have changed.
///
/// Two `DispatchSource`s cover the two ways files actually change on macOS:
/// - a source on the **file's own fd** (`.write`/`.extend`) catches
///   in-place writes (`fs.write` without replacing the inode);
/// - a source on the **parent directory's fd** (`.write`) catches
///   atomic-replace saves (write-temp-file + `rename()`, how most editors
///   and coding agents save) and delete/recreate, both of which orphan the
///   file fd without ever signaling `.write` on it.
///
/// Survives, per PLAN §4/M2 scope:
/// - atomic replace: directory `.write` fires, we re-open the path (new
///   inode) and treat it as a change.
/// - delete then recreate later: the file source reports `.delete`; we
///   detach it and keep watching the directory only. When the directory
///   changes again we re-stat the path; if it exists we re-attach and
///   reload, otherwise we stay in the "removed" state (reported via
///   `onRemovedChanged`) until it does, or forever if it doesn't.
/// - renamed to a different path: indistinguishable, from a path+directory
///   watch, from "deleted" — reported as removed (documented simplification;
///   following an arbitrary rename would need reading the old fd directly).
///
/// `@unchecked Sendable`: every piece of mutable state is confined to
/// `queue` (the sources, timers, and `expectedWrite` are only ever touched
/// inside blocks dispatched onto it), so the type is safe to capture in the
/// `@Sendable` `queue.async` closures even though the compiler can't prove
/// that confinement. The two callback vars are set once at wiring time before
/// any event can fire.
final class FileWatcher: @unchecked Sendable {
    private let path: URL
    private let queue = DispatchQueue(label: "marco.filewatcher")
    private let debounceInterval: TimeInterval
    private let removedGracePeriod: TimeInterval

    /// Called (on `queue`) after a debounced burst of changes settles.
    /// Hop back to the main actor in the callback if touching UI state.
    var onReload: (() -> Void)?
    /// Called (on `queue`) when the removed/present state changes.
    var onRemovedChanged: ((Bool) -> Void)?

    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private var debounceTimer: DispatchSourceTimer?
    private var removedGraceTimer: DispatchSourceTimer?
    /// Whether `onRemovedChanged(true)` has actually been reported to the
    /// UI yet. Distinct from "currently missing on disk": a delete
    /// immediately followed by a recreate (the common editor/agent save
    /// pattern) should never surface a "file removed" flicker — only a
    /// disappearance that outlasts `removedGracePeriod` is reported.
    private var hasReportedRemoved = false
    private var expectedContents: Data?

    private static let log = Logger(subsystem: "com.dee.marco.draft", category: "FileWatcher")

    init(url: URL, debounceInterval: TimeInterval = 0.08, removedGracePeriod: TimeInterval = 3.0) {
        self.path = url
        self.debounceInterval = debounceInterval
        self.removedGracePeriod = removedGracePeriod
        queue.async { [weak self] in self?.attachAll() }
    }

    func whenReady(_ callback: @escaping @Sendable () -> Void) {
        queue.async(execute: callback)
    }

    deinit {
        fileSource?.cancel()
        dirSource?.cancel()
        debounceTimer?.cancel()
        removedGraceTimer?.cancel()
    }

    /// Suppress only an event whose current file still matches our saved bytes.
    func expectOwnWrite(contents: Data) {
        queue.async { [weak self] in
            self?.expectedContents = contents
        }
    }

    // MARK: - Attaching

    private func attachAll() {
        attachFileSource()
        attachDirectorySource()
    }

    private func attachFileSource() {
        fileSource?.cancel()
        fileSource = nil
        let fd = open(path.path, O_EVTONLY)
        guard fd >= 0 else {
            // File doesn't exist right now (e.g. mid delete/recreate) —
            // the directory source will tell us when it reappears.
            startRemovedGraceTimer()
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                self.handlePossibleRemoval()
            } else {
                self.markRestoredIfNeeded()
                self.scheduleDebouncedReload()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
        markRestoredIfNeeded()
    }

    private func attachDirectorySource() {
        let dir = path.deletingLastPathComponent()
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else {
            Self.log.error("FileWatcher: couldn't open parent directory \(dir.path, privacy: .public) errno=\(errno)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleDirectoryChange()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        dirSource = source
    }

    // MARK: - Event handling

    /// The file's own fd reported delete/rename: the inode our fd points
    /// to is gone from this path (atomic-replace unlinks the old inode, a
    /// real delete leaves nothing). Re-check the path itself to tell those
    /// two cases apart.
    private func handlePossibleRemoval() {
        fileSource?.cancel()
        fileSource = nil
        if FileManager.default.fileExists(atPath: path.path) {
            // Atomic-replace: a new inode already lives at this path.
            attachFileSource()
            scheduleDebouncedReload()
        } else {
            startRemovedGraceTimer()
        }
    }

    /// The parent directory changed (any entry created/removed/renamed).
    /// If we're currently detached (removed) and the path has reappeared,
    /// re-attach and reload. If we're attached, a directory write can still
    /// mean an atomic-replace we haven't otherwise noticed yet — re-check.
    private func handleDirectoryChange() {
        let exists = FileManager.default.fileExists(atPath: path.path)
        if exists, fileSource == nil {
            attachFileSource()
            scheduleDebouncedReload()
        } else if exists {
            scheduleDebouncedReload()
        }
        // If it still doesn't exist, keep waiting — the grace timer (if
        // running) handles the "gone for good" report.
    }

    /// Starts (or restarts) the grace-period countdown after the file
    /// disappears. Only fires `onRemovedChanged(true)` if the file is
    /// STILL missing once the timer elapses — a delete immediately
    /// followed by a recreate (already handled by `handleDirectoryChange`/
    /// `attachFileSource` before this fires) never reports removed at all.
    private func startRemovedGraceTimer() {
        guard removedGraceTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + removedGracePeriod)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.removedGraceTimer = nil
            if self.fileSource == nil, !FileManager.default.fileExists(atPath: self.path.path) {
                self.hasReportedRemoved = true
                self.onRemovedChanged?(true)
            }
        }
        timer.resume()
        removedGraceTimer = timer
    }

    /// Cancels any pending removed-report and, if we'd already reported
    /// removed, reports restored.
    private func markRestoredIfNeeded() {
        removedGraceTimer?.cancel()
        removedGraceTimer = nil
        if hasReportedRemoved {
            hasReportedRemoved = false
            onRemovedChanged?(false)
        }
    }

    private func scheduleDebouncedReload() {
        debounceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + debounceInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if let expected = self.expectedContents {
                self.expectedContents = nil
                if (try? Data(contentsOf: self.path)) == expected { return }
            }
            self.onReload?()
        }
        timer.resume()
        debounceTimer = timer
    }
}
