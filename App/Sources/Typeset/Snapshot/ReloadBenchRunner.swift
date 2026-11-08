import AppKit
import Foundation
import TypesetCore

// Debug-only: this diagnostic entry point never ships in Release (PLAN §8).
#if DEBUG

/// Headless live-reload verification path, mirroring `SnapshotRunner`'s
/// `TYPESET_SNAPSHOT` pattern: drives the real `DocumentReloadController` +
/// `FileWatcher` pipeline against a real file on disk, entirely in-process
/// and without a visible window, and prints one line per applied reload
/// (block count, changed-block count, measured latency) to stderr. Used to
/// verify + measure M2 live reload end-to-end from a shell script that
/// edits the watched file while this runs.
///
///   TYPESET_RELOAD_BENCH=/path/to/file.md
///   TYPESET_RELOAD_BENCH_COUNT=3     (optional: exit after this many reloads)
///   TYPESET_RELOAD_BENCH_TIMEOUT=20  (optional: exit after this many seconds)
@MainActor
enum ReloadBenchRunner {
    /// Keeps the bench's `DocumentReloadController` alive for the whole
    /// process. In the real app the controller is retained by
    /// `DocumentWindow`'s `@State`; here there is no window, so without this
    /// the controller (and its `FileWatcher`) would deallocate the moment
    /// `runIfRequested()` returns — `FileWatcher.deinit` cancels its dispatch
    /// sources, so every subsequent file change would go unobserved.
    private static var retainedController: DocumentReloadController?

    static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TYPESET_RELOAD_BENCH"] else { return false }

        let expectedCount = env["TYPESET_RELOAD_BENCH_COUNT"].flatMap { Int($0) } ?? 3
        let timeout = env["TYPESET_RELOAD_BENCH_TIMEOUT"].flatMap { Double($0) } ?? 20.0
        let url = URL(fileURLWithPath: path)

        let controller = DocumentReloadController(url: url)
        retainedController = controller
        var observedCount = 0

        func log(_ message: String) {
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }

        controller.onReloadApplied = { report in
            observedCount += 1
            log(
                "reload-bench: reload #\(observedCount) blocks=\(report.blockCount) "
                    + "changed=\(report.changedCount) elapsedMs=\(String(format: "%.2f", report.elapsedMilliseconds))"
            )
            if observedCount >= expectedCount {
                NSApplication.shared.terminate(nil)
            }
        }

        controller.start()
        controller.onInitialLoaded = {
            log(
                "reload-bench: watching \(path), initial blocks=\(controller.blocks.count)"
                    + (controller.loadError.map { " loadError=\($0)" } ?? "")
            )
        }

        Task {
            try? await Task.sleep(for: .seconds(timeout))
            log("reload-bench: timed out after \(timeout)s with \(observedCount) reload(s) observed")
            NSApplication.shared.terminate(nil)
        }

        return true
    }
}
#endif
