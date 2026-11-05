import AppKit
import CryptoKit
import Foundation
import MarcoCore
import MarcoRendering

// Debug-only: this diagnostic entry point never ships in Release (PLAN §8).
#if DEBUG

/// Headless M3 verification path, mirroring `ReloadBenchRunner`'s
/// `MARCO_RELOAD_BENCH` pattern: drives the real `DocumentReloadController`
/// M3 surface (checkbox write-back, save, conflict banner) against a real
/// file on disk, entirely in-process without a visible window, and reports
/// pass/fail for each scenario to stderr.
///
///   MARCO_EDIT_BENCH=/path/to/fixture.md   (must contain at least one
///                                            top-level `- [ ] ...` task item)
@MainActor
enum EditBenchRunner {
    private static var retainedController: DocumentReloadController?

    static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["MARCO_EDIT_BENCH"] else { return false }
        let url = URL(fileURLWithPath: path)

        func log(_ message: String) {
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }

        var allPassed = true
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            let passed = condition()
            log("edit-bench: \(passed ? "PASS" : "FAIL") — \(name)")
            if !passed { allPassed = false }
        }

        let controller = DocumentReloadController(url: url)
        retainedController = controller
        var reloadCount = 0
        controller.onReloadApplied = { _ in reloadCount += 1 }
        controller.start()

        Task {
            while controller.isLoading { try? await Task.sleep(for: .milliseconds(10)) }
            log("edit-bench: watching \(path), initial blocks=\(controller.blocks.count)")
            // MARK: Scenario 1 — checkbox write-back, no reload pulse
            guard let (blockStartLine, lineOffset, currentlyChecked) = firstCheckboxLocation(in: controller) else {
                log("edit-bench: FAIL — no task-list checkbox found in fixture; aborting")
                NSApplication.shared.terminate(nil)
                return
            }
            let targetChecked = !currentlyChecked
            let beforeToggle = try? String(contentsOf: url, encoding: .utf8)
            controller.toggleCheckbox(blockStartLine: blockStartLine, itemLineOffset: lineOffset, checked: targetChecked)
            try? await Task.sleep(for: .milliseconds(300))
            let afterToggle = try? String(contentsOf: url, encoding: .utf8)
            check("checkbox toggle changed file content", beforeToggle != afterToggle)
            check("checkbox toggle produced exactly the expected line flip",
                  CheckboxWriteBack.flip(fileText: beforeToggle ?? "", blockStartLine: blockStartLine, itemLineOffset: lineOffset, checked: targetChecked) == afterToggle)
            check("checkbox toggle did not trigger a watcher reload pulse (own-write suppressed)", reloadCount == 0)

            // MARK: Scenario 2 — save path, checksummed, own-write suppressed
            _ = controller.enterEditMode()
            let editedText = controller.editedText + "\n\nAppended by edit-bench.\n"
            controller.noteEditedTextChanged(editedText)
            check("editing the buffer marks the session dirty", controller.conflictState == .dirty)
            controller.save()
            check("save() settles the session back to clean", controller.conflictState == .clean)
            let onDiskAfterSave = try? Data(contentsOf: url)
            let expectedChecksum = SHA256.hash(data: Data(editedText.utf8))
            let actualChecksum = onDiskAfterSave.map { SHA256.hash(data: $0) }
            check("saved file checksum matches the edited buffer", actualChecksum.map { "\($0)" } == "\(expectedChecksum)")
            check("save() did not trigger a watcher reload pulse (own-write suppressed)", reloadCount == 0)
            _ = controller.exitEditMode(caretLine: 0)

            // MARK: Scenario 3 — conflict banner: dirty buffer + external change
            //
            _ = controller.enterEditMode()
            controller.noteEditedTextChanged(controller.editedText + "\n\nLocal in-progress edit.\n")
            check("buffer is dirty going into the conflict scenario", controller.conflictState == .dirty)
            let currentOnDisk = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let externalContent = currentOnDisk + "\n\nExternal change from another process.\n"
            try? Data(externalContent.utf8).write(to: url, options: .atomic)
            try? await Task.sleep(for: .milliseconds(400))
            check("external change while dirty surfaces the conflict banner, not a silent reload",
                  controller.conflictState == .conflictPending)
            controller.resolveConflictTakeTheirs()
            try? await Task.sleep(for: .milliseconds(300))
            check("'Take theirs' returns to clean and adopts the external content",
                  controller.conflictState == .clean && controller.editedText == externalContent)
            controller.exitEditMode(caretLine: 0)

            log("edit-bench: \(allPassed ? "ALL SCENARIOS PASSED" : "ONE OR MORE SCENARIOS FAILED")")
            NSApplication.shared.terminate(nil)
        }

        Task {
            try? await Task.sleep(for: .seconds(15))
            log("edit-bench: timed out")
            NSApplication.shared.terminate(nil)
        }

        return true
    }

    private static func firstCheckboxLocation(in controller: DocumentReloadController) -> (Int, Int, Bool)? {
        let document = NativeMarkdownDocument.build(
            source: controller.currentText, blocks: controller.blocks,
            theme: Theme(colorScheme: .light, scale: 1), documentURL: controller.url)
        return document.checkboxes.first.map { ($0.blockStartLine, $0.lineOffset, $0.checked) }
    }
}
#endif
