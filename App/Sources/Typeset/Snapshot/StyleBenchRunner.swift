import AppKit
import Foundation

// Debug-only: this diagnostic entry point never ships in Release (PLAN §8).
#if DEBUG

/// Headless timing check for `MarkdownSyntaxStyler` (M3 source editor
/// styling), mirroring the other `TYPESET_*_BENCH` headless paths: loads a
/// fixture into a real `NSTextStorage` and times a whole-document style
/// pass (load / appearance-change cost) plus a single-paragraph incremental
/// pass (per-keystroke cost) — the two costs PLAN §1 budgets as "instant."
///
///   TYPESET_STYLE_BENCH=/path/to/fixture.md
@MainActor
enum StyleBenchRunner {
    static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TYPESET_STYLE_BENCH"] else { return false }
        let url = URL(fileURLWithPath: path)

        func log(_ message: String) {
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }

        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            log("style-bench: couldn't read \(path)")
            NSApplication.shared.terminate(nil)
            return true
        }

        let font = SourceEditorView.font
        let colors = MarkdownSyntaxStyler.Colors(
            heading: .labelColor, link: .linkColor, code: .systemBlue,
            codeBackground: .systemBlue.withAlphaComponent(0.1), dim: .tertiaryLabelColor)

        let storage = NSTextStorage(string: text)
        let start = DispatchTime.now()
        MarkdownSyntaxStyler.styleFullDocument(storage, baseFont: font, colors: colors)
        let fullMs = millis(since: start)
        log("style-bench: \(url.lastPathComponent) (\(text.utf8.count) bytes) whole-document style = \(fullMs)ms")

        // Simulate one keystroke near the middle of the document: an
        // NSTextStorageDelegate-style edited range of length 1 at the
        // midpoint, restyled incrementally.
        let midpoint = storage.length / 2
        let editedRange = NSRange(location: midpoint, length: min(1, storage.length - midpoint))
        let incStart = DispatchTime.now()
        MarkdownSyntaxStyler.styleEdited(storage, editedRange: editedRange, baseFont: font, colors: colors)
        let incMs = millis(since: incStart)
        log("style-bench: one incremental (edited-paragraph) restyle = \(incMs)ms")

        NSApplication.shared.terminate(nil)
        return true
    }

    private static func millis(since start: DispatchTime) -> String {
        String(format: "%.3f", Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }
}
#endif
