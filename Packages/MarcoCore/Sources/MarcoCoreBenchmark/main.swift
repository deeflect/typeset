import Foundation
import MarcoCore

// Release-mode perf harness. Run with:
//   swift run -c release MarcoCoreBenchmark
//
// Reads fixtures from Tests/Fixtures/generated (see Scripts/make-fixtures.sh)
// relative to the repo root, located via this source file's own path so it
// works regardless of the current working directory `swift run` is invoked
// from.

func repoRoot() -> URL {
    // .../Packages/MarcoCore/Sources/MarcoCoreBenchmark/main.swift -> repo root
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // MarcoCoreBenchmark/
        .deletingLastPathComponent()  // Sources/
        .deletingLastPathComponent()  // MarcoCore/
        .deletingLastPathComponent()  // Packages/
        .deletingLastPathComponent()  // repo root
}

func fixture(_ name: String) -> String? {
    let path = repoRoot().appendingPathComponent("Tests/Fixtures/generated/\(name)")
    return try? String(contentsOf: path, encoding: .utf8)
}

func currentRSSBytes() -> Int64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int64(info.resident_size) : -1
}

func formatBytes(_ bytes: Int64) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_048_576)
}

print("=== MarcoCore parser benchmark ===\n")

// Warm up cmark/CryptoKit lazy setup so the first fixture's numbers aren't
// skewed by one-time initialization cost.
_ = MarkdownParser.parse("# warmup\n\nparagraph\n")

var keepAlive: [[Block]] = []

for name in ["large-200kb.md", "large-1mb.md", "large-10mb.md"] {
    guard let text = fixture(name) else {
        print("\(name): fixture missing — run Scripts/make-fixtures.sh first\n")
        continue
    }
    print("--- \(name) (\(formatBytes(Int64(text.utf8.count)))) ---")

    let rssBefore = currentRSSBytes()
    let (blocks, timing) = MarkdownParser.parseMeasured(text)
    let rssAfter = currentRSSBytes()

    print("  blocks: \(blocks.count)")
    print(String(format: "  total:               %.4fs", timing.total))
    print(String(format: "  frontmatterSplit:    %.4fs", timing.frontmatterSplit))
    print(String(format: "  cmarkParse:          %.4fs", timing.cmarkParse))
    print(String(format: "  lineSplit:           %.4fs", timing.lineSplit))
    print(String(format: "  blockClassification: %.4fs", timing.blockClassification))
    print(String(format: "  sourceTextSlicing:   %.4fs", timing.sourceTextSlicing))
    print(String(format: "  blockInit+hashing:   %.4fs", timing.blockConstructionAndHashing))
    print("  RSS delta while parsing (approx, incl. transients): \(formatBytes(rssAfter - rssBefore))")

    // Keep the result alive so a second RSS sample after all fixtures
    // isolates the steady-state cost of holding [Block] arrays.
    keepAlive.append(blocks)
    print("")
}

let steadyStateRSS = currentRSSBytes()
print("Steady-state RSS holding all parsed [Block] arrays alive: \(formatBytes(steadyStateRSS))")

// Progressive parse: time-to-first-chunk on the 10 MB fixture (budget: < 300 ms).
if let text = fixture("large-10mb.md") {
    print("\n--- large-10mb.md progressive parse ---")
    let start = CFAbsoluteTimeGetCurrent()
    var firstChunkElapsed: Double?
    var totalBlocks = 0
    var chunkCount = 0
    for await chunk in MarkdownParser.parseProgressive(text) {
        if firstChunkElapsed == nil {
            firstChunkElapsed = CFAbsoluteTimeGetCurrent() - start
        }
        totalBlocks += chunk.count
        chunkCount += 1
    }
    let totalElapsed = CFAbsoluteTimeGetCurrent() - start
    print(String(format: "  time to first chunk: %.4fs (budget < 0.3s)", firstChunkElapsed ?? -1))
    print(String(format: "  time to all chunks:  %.4fs", totalElapsed))
    print("  chunks: \(chunkCount), total blocks: \(totalBlocks)")
}

// Incremental reparse: one paragraph edit in the 1 MB fixture (budget: < 50 ms).
if let text = fixture("large-1mb.md") {
    print("\n--- large-1mb.md incremental reparse (one paragraph edit) ---")
    let oldBlocks = MarkdownParser.parse(text)
    let newText = text.replacingOccurrences(of: "Paragraph 500 with", with: "Paragraph 500 EDITED with")
    let start = CFAbsoluteTimeGetCurrent()
    let newBlocks = MarkdownParser.reparseIncremental(oldText: text, newText: newText, oldBlocks: oldBlocks)
    let elapsed = CFAbsoluteTimeGetCurrent() - start
    print(String(format: "  incremental reparse: %.4fs (budget < 0.05s)", elapsed))
    print("  blocks: \(newBlocks.count) (was \(oldBlocks.count))")
}

