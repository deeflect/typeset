import Foundation
import TypesetCore

// Release-mode perf harness. Run with:
//   swift run -c release TypesetCoreBenchmark
//
// Reads fixtures from Tests/Fixtures/generated (see Scripts/make-fixtures.sh)
// relative to the repo root, located via this source file's own path so it
// works regardless of the current working directory `swift run` is invoked
// from.

func repoRoot() -> URL {
    // .../Packages/TypesetCore/Sources/TypesetCoreBenchmark/main.swift -> repo root
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // TypesetCoreBenchmark/
        .deletingLastPathComponent()  // Sources/
        .deletingLastPathComponent()  // TypesetCore/
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

print("=== TypesetCore parser benchmark ===\n")

// Warm up cmark/CryptoKit lazy setup so the first fixture's numbers aren't
// skewed by one-time initialization cost.
_ = MarkdownParser.parse("# warmup\n\nparagraph\n")

// MARK: - Phase timing (goal 1: where does parse time go)

var keepAlive: [[Block]] = []

for name in ["large-200kb.md", "large-1mb.md", "large-10mb.md"] {
    guard let text = fixture(name) else {
        print("\(name): fixture missing — run Scripts/make-fixtures.sh first\n")
        continue
    }
    print("--- \(name) (\(formatBytes(Int64(text.utf8.count)))) ---")

    let (blocks, timing) = MarkdownParser.parseMeasured(text)

    print("  blocks: \(blocks.count)")
    print(String(format: "  total:               %.4fs", timing.total))
    print(String(format: "  frontmatterSplit:    %.4fs", timing.frontmatterSplit))
    print(String(format: "  cmarkParse:          %.4fs", timing.cmarkParse))
    print(String(format: "  lineSplit:           %.4fs", timing.lineSplit))
    print(String(format: "  blockClassification: %.4fs", timing.blockClassification))
    print(String(format: "  sourceTextSlicing:   %.4fs", timing.sourceTextSlicing))
    print(String(format: "  blockInit+hashing:   %.4fs", timing.blockConstructionAndHashing))

    keepAlive.append(blocks)
    print("")
}

// MARK: - Incremental reparse (goal 4: budget < 50ms for a 1-paragraph edit)

if let text = fixture("large-1mb.md") {
    print("--- large-1mb.md incremental reparse (one paragraph edit) ---")
    let oldBlocks = MarkdownParser.parse(text)
    let newText = text.replacingOccurrences(of: "Paragraph 500 with", with: "Paragraph 500 EDITED with")
    let start = CFAbsoluteTimeGetCurrent()
    let newBlocks = MarkdownParser.reparseIncremental(oldText: text, newText: newText, oldBlocks: oldBlocks)
    let elapsed = CFAbsoluteTimeGetCurrent() - start
    print(String(format: "  incremental reparse: %.4fs (budget < 0.05s)", elapsed))
    print("  blocks: \(newBlocks.count) (was \(oldBlocks.count))")
    print("")
}

// MARK: - Memory (goal 5)
//
// Finding: the ~650-800 MB RSS this process holds after parsing the 10 MB
// fixture even once is NOT the Swift [Block] array — it's cmark-gfm's own
// internal arena allocator (arena.c), which grows on demand to fit the
// input and is never shrunk for the lifetime of the process. Evidence:
// parsing the *same or a different* 10 MB text again, discarding the
// Swift result every time, shows ~0 MB further growth — all the growth
// happens on the very first large parse. This is a cmark-gfm allocator
// characteristic, not something fixable from TypesetCore's Swift layer
// without vendoring/patching the C dependency (out of scope here; noted
// as an open risk in the write-up).
//
// What *is* addressable at the Swift level is [Block]'s own retained
// footprint, which this measures by summing content bytes directly
// rather than relying on process RSS (which the arena finding shows is
// dominated by something else entirely).
if let text = fixture("large-10mb.md") {
    let blocks = MarkdownParser.parse(text)
    var rawTextBytes = 0
    for b in blocks { rawTextBytes += b.rawText.utf8.count }
    // digest is a 32-byte inline SIMD value (no heap allocation), so the
    // per-block Swift-level footprint beyond rawText is small and fixed:
    // ~32 bytes digest + kind + ordinal + startLine, no separate hash
    // string allocation.
    print("--- large-10mb.md [Block] footprint (goal 5) ---")
    print("  blocks: \(blocks.count)")
    print("  sum(rawText.utf8.count): \(formatBytes(Int64(rawTextBytes))) (source file: \(formatBytes(Int64(text.utf8.count))))")
    print("  contentHash is now computed on demand from an inline 32-byte digest,")
    print("  not stored as a heap-allocated 64-char String (was ~235k extra small")
    print("  heap allocations for the 10 MB fixture before this change).")
}
