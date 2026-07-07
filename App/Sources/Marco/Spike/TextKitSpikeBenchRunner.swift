import AppKit
import MarcoCore
import MarcoRendering
import SwiftUI

// Debug-only: throwaway M6 Phase 0 spike harness (M6-PLAN.md §6). Drives one
// measurement (renderer x fixture) per process invocation, prints a results
// block to stderr, then quits — the same one-shot-per-process shape as
// Spike A (`worktree-agent-a4f60def476157318`, PLAN §8 decision log) so a
// hang in one combo can be capped with a shell-level `timeout` without
// corrupting later measurements. Builds its own `NSWindow` directly (rather
// than routing through `MarcoApp`'s `WindowGroup`) so this file is the only
// thing that needs to exist for the spike — no changes to the app's normal
// window plumbing.
//
//   MARCO_TEXTKIT_SPIKE_BENCH=/path/to/fixture.md
//   MARCO_TEXTKIT_SPIKE_RENDERER=textkit2|lazyvstack
//   MARCO_TEXTKIT_SPIKE_IMAGE_DIR=/path/to/dir   (optional: resolves image
//                                                  refs + inserts attachments;
//                                                  set for the image-heavy
//                                                  fixture only)
#if DEBUG

@MainActor
enum TextKitSpikeBenchRunner {
    static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["MARCO_TEXTKIT_SPIKE_BENCH"] else { return false }
        guard let rendererRaw = env["MARCO_TEXTKIT_SPIKE_RENDERER"],
            let renderer = SpikeRenderer(rawValue: rendererRaw)
        else {
            FileHandle.standardError.write(Data("textkit-spike: missing/invalid MARCO_TEXTKIT_SPIKE_RENDERER\n".utf8))
            NSApp.terminate(nil)
            return true
        }
        let imageDir = env["MARCO_TEXTKIT_SPIKE_IMAGE_DIR"].map { URL(fileURLWithPath: $0) }

        Task { await SpikeBenchDriver.shared.run(path: path, renderer: renderer, imageDir: imageDir) }
        return true
    }
}

enum SpikeRenderer: String { case textkit2, lazyvstack }

@MainActor
final class SpikeBenchDriver {
    static let shared = SpikeBenchDriver()

    private var window: NSWindow?
    private var log: [String] = []
    /// Keeps the TextKit 2 stack alive for the run's duration (see
    /// `TextKit2SpikeFactory.Retained`'s doc comment).
    private var textKit2Retained: TextKit2SpikeFactory.Retained?

    func run(path: String, renderer: SpikeRenderer, imageDir: URL?) async {
        line("=== TextKit2 spike: \(renderer.rawValue) / \((path as NSString).lastPathComponent) ===")
        let url = URL(fileURLWithPath: path)

        let tReadStart = now()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            line("FAILED to read \(path)")
            finish()
            return
        }
        let tReadEnd = now()
        line("read: \(ms(tReadEnd - tReadStart)) ms (\(text.utf8.count) bytes)")

        let memBaseline = MemorySampler.residentMB()

        let tParseStart = now()
        let blocks = MarkdownParser.parse(text)
        let tParseEnd = now()
        line("parse: \(ms(tParseEnd - tParseStart)) ms, \(blocks.count) blocks")

        // Plain AppKit window/content construction — no SwiftUI state
        // indirection needed since the renderer is fixed for the whole run.
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 800))

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        win.contentView = containerView
        win.title = "TextKit2 Spike"
        win.makeKeyAndOrderFront(nil)
        window = win
        NSApp.activate(ignoringOtherApps: true)

        let tBeforeApply = now()

        // A single content `NSView` per renderer, added as a sibling of the
        // display-link host: for `.textkit2` this IS the `NSScrollView`
        // directly; for `.lazyvstack` it's an `NSHostingView` wrapping the
        // real SwiftUI `ScrollView`/`LazyVStack` — its underlying
        // `NSScrollView` is located afterwards via `ScrollViewFinder`, same
        // as Spike A did for MarkdownUI/the custom renderer.
        var textKit2Retained: TextKit2SpikeFactory.Retained?
        let contentView: NSView
        switch renderer {
        case .textkit2:
            let tStyleStart = now()
            let storage = TextKit2SpikeStyler.buildStorage(text: text, blocks: blocks)
            if let imageDir {
                TextKit2SpikeStyler.insertImageAttachments(into: storage, baseDirectory: imageDir)
            }
            let tStyleEnd = now()
            line("style: \(ms(tStyleEnd - tStyleStart)) ms")
            let (sv, retained) = TextKit2SpikeFactory.makeScrollView(storage: storage, containerWidth: 852)
            textKit2Retained = retained
            contentView = sv
        case .lazyvstack:
            let theme = Theme(colorScheme: .light, scale: 1.0)
            contentView = NSHostingView(rootView:
                SpikeLazyVStackView(blocks: blocks, documentURL: url)
                    .environment(\.theme, theme)
            )
        }
        contentView.frame = NSRect(x: 0, y: 0, width: 900, height: 800)
        contentView.autoresizingMask = [.width, .height]
        containerView.addSubview(contentView)
        self.textKit2Retained = textKit2Retained

        guard let scrollView = await waitForScrollView(timeout: 20) else {
            line("time-to-first-frame: TIMEOUT (no NSScrollView found — main thread likely stalled)")
            finish()
            return
        }

        // "First frame" proxy: the document view's height stabilizing, same
        // technique Spike A used (LazyVStack settles once initial layout
        // completes; TextKit 2's viewport layout settles once the visible
        // fragments + its height *estimate* for the rest stop changing).
        var lastHeight: CGFloat = -1
        var stableCount = 0
        let stabilized = await waitUntil(timeout: 20) {
            let h = scrollView.documentView?.frame.height ?? -1
            if abs(h - lastHeight) < 0.5 { stableCount += 1 } else { stableCount = 0 }
            lastHeight = h
            return stableCount >= 3
        }
        let tFirstFrame = now()
        if stabilized {
            line("time-to-first-frame: \(ms(tFirstFrame - tBeforeApply)) ms (doc height \(Int(lastHeight)) pt)")
        } else {
            line("time-to-first-frame: TIMEOUT after 20s (doc height still changing, last=\(Int(lastHeight)) pt)")
        }

        // Driven fling top -> bottom in 60 steps, timing each step's
        // synchronous layout+draw cost directly (`displayIfNeeded()` forces
        // AppKit to lay out and paint the newly-scrolled-to region before the
        // next step) rather than via `CADisplayLink`: in this headless,
        // never-user-interacted harness, `CADisplayLink` was observed to
        // simply never fire once a fixture got large enough (repros at
        // 1 MB+ on both renderers — a harness limitation, not a rendering
        // finding), so it isn't a reliable clock here.
        //
        // Caveat (`.lazyvstack` only): `displayIfNeeded()` forces the
        // `NSHostingView`'s own AppKit-level display pass, but SwiftUI's
        // internal diffing/reconciliation for the new scroll offset is
        // coalesced onto the run loop asynchronously and is NOT forced
        // synchronous by this call (confirmed: forcing a `CATransaction
        // .flush()` immediately after to try to make it synchronous instead
        // reproduced the same "never returns" harness hang as `CADisplayLink`
        // did) — so `.lazyvstack` step times below are a floor, not a real
        // per-frame cost, and are NOT used for the scroll-parity verdict.
        // The scroll gate instead compares TextKit 2's numbers here (real,
        // synchronous AppKit cost) against the existing trusted LazyVStack
        // baseline in BENCHMARKS.md (~17 ms/frame at 1 MB/10 MB, measured via
        // `CADisplayLink` in a real interactive run — PLAN §8 Spike A).
        let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height)
        let steps = 60
        var stepMs: [Double] = []
        for i in 0...steps {
            let y = maxY * (Double(i) / Double(steps))
            let t0 = now()
            scrollView.contentView.setBoundsOrigin(CGPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            scrollView.displayIfNeeded()
            stepMs.append((now() - t0) * 1000)
        }
        let sortedSteps = stepMs.sorted()
        let meanStep = stepMs.reduce(0, +) / Double(stepMs.count)
        let p95Step = sortedSteps[Int(Double(sortedSteps.count - 1) * 0.95)]
        let maxStep = sortedSteps.last ?? 0
        let hitches = stepMs.filter { $0 > 26.7 }.count
        line(
            "scroll fling: \(stepMs.count) steps, mean \(round1(meanStep)) ms, "
                + "p95 \(round1(p95Step)) ms, max \(round1(maxStep)) ms, "
                + "hitches(>26.7ms) \(hitches)")

        let memAfterFling = MemorySampler.residentMB()
        line("memory: baseline \(round1(memBaseline)) MB -> after fling \(round1(memAfterFling)) MB (RSS, in-process sample)")

        // Height-estimate / scroll-jump drift probe (PLAN §8 risk 1): jump
        // directly to ~90% scroll depth *without* having traversed (and
        // therefore laid out) most of the document first — the documented
        // TextKit 2 weak spot is that unlaid regions contribute an
        // *estimated* height to `usageBoundsForTextContainer`, which is
        // revised once those regions actually lay out, shifting content
        // that was already on screen. We approximate that shift as the
        // delta between the document height measured right after the jump
        // and the height once layout has had time to settle. This is a
        // proxy, not a full anchor-preserving repro (that needs the app's
        // real scroll-position/anchor machinery) — labeled as such in
        // BENCHMARKS.md.
        let jumpY = maxY * 0.9
        scrollView.contentView.setBoundsOrigin(.zero) // reset scroll state first
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollView.displayIfNeeded()
        let heightBeforeJump = scrollView.documentView?.frame.height ?? 0
        let originBeforeSettle = jumpY
        let tJumpStart = now()
        scrollView.contentView.setBoundsOrigin(CGPoint(x: 0, y: jumpY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollView.displayIfNeeded()
        let jumpMs = (now() - tJumpStart) * 1000
        try? await Task.sleep(nanoseconds: 500_000_000) // let any deferred layout settle
        let heightAfterSettle = scrollView.documentView?.frame.height ?? 0
        let originAfterSettle = scrollView.contentView.bounds.origin.y
        line(
            "height-drift probe: doc height before jump \(Int(heightBeforeJump)) pt -> after settle \(Int(heightAfterSettle)) pt "
                + "(delta \(Int(heightAfterSettle - heightBeforeJump)) pt); "
                + "content origin.y requested \(Int(originBeforeSettle)) -> actual after settle \(Int(originAfterSettle)) "
                + "(drift \(Int(originAfterSettle - originBeforeSettle)) pt); "
                + "jump-to-90% step cost \(round1(jumpMs)) ms")

        finish()
    }

    private func waitForScrollView(timeout: Double) async -> NSScrollView? {
        var found: NSScrollView?
        _ = await waitUntil(timeout: timeout) {
            guard let root = self.window?.contentView else { return false }
            found = ScrollViewFinder.find(in: root)
            return found != nil
        }
        return found
    }

    private func waitUntil(timeout: Double, _ condition: @escaping () -> Bool) async -> Bool {
        let start = now()
        while now() - start < timeout {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        return condition()
    }

    private func now() -> CFTimeInterval { CFAbsoluteTimeGetCurrent() }
    private func ms(_ t: CFTimeInterval) -> String { String(format: "%.1f", t * 1000) }
    private func round1(_ d: Double) -> String { String(format: "%.1f", d) }

    private func line(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
        log.append(s)
    }

    private func finish() {
        NSApp.terminate(nil)
    }
}


/// Manual recursive search for the content `NSScrollView` — both renderers
/// under test embed a `ScrollView`/`NSScrollView` somewhere in their view
/// tree, and the harness needs to drive its offset directly.
@MainActor
enum ScrollViewFinder {
    static func find(in view: NSView) -> NSScrollView? {
        if let sv = view as? NSScrollView { return sv }
        for sub in view.subviews {
            if let found = find(in: sub) { return found }
        }
        return nil
    }
}

// MARK: - Memory sampling

enum MemorySampler {
    /// Resident set size in MB via `task_info`/`MACH_TASK_BASIC_INFO` — an
    /// in-process, tool-free RSS sample, stable enough to compare two
    /// renderers on the same box within one run.
    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return -1 }
        return Double(info.resident_size) / 1024 / 1024
    }
}
#endif
