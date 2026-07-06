import AppKit
import Foundation
import MarcoCore

/// Headless ⌘F perf verification, mirroring `SnapshotRunner`'s pattern.
/// Measures the three costs that gate find responsiveness on a large file:
/// building the searchable segments (paid once when the bar opens / on each
/// reload), running `FindEngine` over them, and applying match tints to a
/// screenful of blocks (paid per render frame while find is open). Prints the
/// numbers to stderr and exits.
///
///   MARCO_FIND_BENCH=/path/to/file.md
///   MARCO_FIND_BENCH_QUERY=block   (optional, default "block")
@MainActor
enum FindBenchRunner {
    static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["MARCO_FIND_BENCH"] else { return false }
        let query = env["MARCO_FIND_BENCH_QUERY"] ?? "block"
        let url = URL(fileURLWithPath: path)

        func log(_ message: String) {
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }

        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            log("find-bench: could not read \(path)")
            return true
        }

        let bytes = text.utf8.count
        let parseStart = DispatchTime.now()
        let blocks = MarkdownParser.parse(text)
        log("find-bench: \(bytes) bytes, \(blocks.count) blocks, query=\"\(query)\"")
        _ = parseStart

        // 1. Segment build (once per open / reload).
        let buildStart = DispatchTime.now()
        let (keys, texts) = FindSegmentBuilder.build(from: blocks)
        let buildMs = ms(since: buildStart)
        log(String(format: "find-bench: segment build: %.1f ms (%d segments)", buildMs, texts.count))

        // 2. Search (once per query change / reload).
        let searchStart = DispatchTime.now()
        let matches = FindEngine.search(query: query, in: texts)
        let searchMs = ms(since: searchStart)
        log(String(format: "find-bench: search: %.2f ms (%d matches)", searchMs, matches.count))

        // 3. Per-block highlight apply (per render frame — LazyVStack only
        // builds a screenful, ~40 blocks, so measure that many).
        let theme = Theme(colorScheme: .dark, scale: 1)
        let currentKey = matches.first.map { keys[$0.segmentIndex] }
        let currentStart = matches.first?.start
        let ctx = FindHighlightContext(query: query, caseSensitive: false, currentKey: currentKey, currentStart: currentStart)

        // Prefer blocks that actually contain a match, to measure the real cost.
        let sampleKeys = Array(Set(matches.prefix(200).map { keys[$0.segmentIndex] }).prefix(40))
        let applyStart = DispatchTime.now()
        for key in sampleKeys {
            guard let index = keys.firstIndex(of: key) else { continue }
            var attr = InlineMarkdown.attributed(texts[index], theme: theme)
            let current = key == currentKey ? ctx.currentStart : nil
            FindHighlighting.apply(to: &attr, query: query, caseSensitive: false, currentStart: current, theme: theme)
        }
        let applyMs = ms(since: applyStart)
        let count = max(sampleKeys.count, 1)
        log(String(format: "find-bench: highlight apply: %.2f ms for %d blocks (%.3f ms/block)", applyMs, sampleKeys.count, applyMs / Double(count)))

        return true
    }

    private static func ms(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }
}
