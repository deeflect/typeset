import AppKit
import MarcoCore
import SwiftUI
import MarcoRendering

/// The reading surface: a `LazyVStack` of per-block views inside a
/// `ScrollView`, keyed by `block.id` so virtualization holds on large
/// documents and unchanged blocks are reused on reload. Prose is capped to
/// the reading measure and centered; the content layer is opaque so glass
/// only ever sits on chrome.
struct DocumentRenderer: View {
    @Bindable var controller: DocumentReloadController
    let model: WindowModel
    let documentURL: URL?
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Click-to-copy feedback (the in-place chip flash + the HUD pulse), held
    /// as a stable injected-once object rather than view `@State`. Mutating it
    /// re-renders only the flashing chip and the HUD — never this `body`, so a
    /// copy tap never re-asserts `\.scrollPosition` on the whole reading
    /// column (which read as the column nudging under the tap).
    @State private var copyFeedback = InlineCopyFeedback()
    /// Headings currently showing the brief arrival pulse after an outline jump
    /// (an accent whisper, reusing the live-reload pulse). Cleared on a timer.
    @State private var arrivalPulseIDs: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(controller.blocks) { block in
                    BlockView(block: block)
                        .id(block.id)
                        .modifier(ChangePulseModifier(
                            isPulsing: controller.pulsedBlockIDs.contains(block.id)
                                || arrivalPulseIDs.contains(block.id)))
                }
            }
            .scrollTargetLayout()
            // Edit ▸ Select All: one contiguous tint over the whole content
            // column. Per-block `Text` can't express a real cross-block
            // selection, so this is what "everything is selected" looks like
            // until the single-text-view reading surface lands.
            .background {
                if model.isSelectAllActive {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .selectedTextBackgroundColor))
                        .padding(.horizontal, -6)
                }
            }
            .frame(maxWidth: theme.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, theme.contentHorizontalPadding)
            .padding(.top, theme.contentTopPadding)
            .padding(.bottom, theme.contentBottomPadding)
            .frame(maxWidth: .infinity, alignment: .center)
            // Keep a stable I-beam across the whole reading column, including
            // the inter-block padding gaps where a per-block `.textSelection`
            // I-beam would otherwise flicker back to the arrow cursor.
            // Interactive descendants (links, the code-copy button, images)
            // override this with their own pointer.
            .pointerStyle(.horizontalText)
        }
        .scrollPosition($controller.scrollPosition)
        // Track which heading's section the reader is in, for the outline
        // dropdown's checkmark. Debounced inside the model.
        .onChange(of: controller.scrollPosition.viewID as? String, initial: true) { _, top in
            model.trackOutline(topBlockID: top)
            // Scrolling away is the natural "never mind" for a select-all.
            model.deselectAll()
        }
        // The outline just jumped to a heading: pulse it so the instant landing
        // reads as an arrival rather than a teleport.
        .onChange(of: model.outlineArrival) { _, arrival in
            guard let arrival else { return }
            pulseArrival(arrival.id)
        }
        .background(theme.background)
        .overlay(alignment: .top) { CopyHUD() }
        .environment(\.documentBaseURL, documentURL)
        // Zero cost when find is closed: `highlightContext` is nil, so block
        // views short-circuit all find work.
        .environment(\.findHighlight, model.find.highlightContext)
        // Injected once (stable identity). Blocks and the HUD read its
        // properties for the flash/pulse; this `body` does not, so a copy tap
        // invalidates only those leaves, never the scroll container.
        .environment(\.inlineCopyFeedback, copyFeedback)
        .environment(\.openURL, OpenURLAction { url in handle(link: url) })
    }

    /// Briefly pulses the arrived heading (the shipped live-reload accent
    /// whisper), then clears it. `ChangePulseModifier` fades on the `false→true`
    /// edge, so the id is removed first — covering a repeat tap on the same row.
    private func pulseArrival(_ id: String) {
        arrivalPulseIDs.remove(id)
        arrivalPulseIDs.insert(id)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            arrivalPulseIDs.remove(id)
        }
    }

    /// Copy an inline-code span to the pasteboard, flash the chip in place, and
    /// fire the secondary HUD. `url` is the chip's own `marco-copy://` link, so
    /// the flash lands on exactly the run that was clicked.
    private func copyInlineCode(_ code: String, url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)

        // In-place chip flash (state feedback — happens under Reduce Motion
        // too, since per-run text can't fade anyway it's a snap either way).
        // Bumping `pulse` also re-shows the HUD, even on a repeat copy of the
        // same chip. Both writes hit only the injected feedback object, so the
        // reading `body` is never invalidated.
        copyFeedback.flashURL = url
        copyFeedback.pulse &+= 1
        let pulse = copyFeedback.pulse
        Task {
            try? await Task.sleep(for: .seconds(Theme.Motion.flashHold))
            // Clear only if no newer copy has claimed the flash since — no
            // stored task to cancel, so nothing on this view is `@State`.
            guard copyFeedback.pulse == pulse else { return }
            copyFeedback.flashURL = nil
        }
    }

    /// Relative `.md` links navigate in-window (with history); `#anchor` links
    /// scroll to the matching heading; other local files reveal in Finder;
    /// http(s) and everything else fall through to the system.
    private func handle(link url: URL) -> OpenURLAction.Result {
        // Click-to-copy inline code (Telegram-style). Handled entirely in the
        // app; the Quick Look extension has no `openURL` handler, so the same
        // link is an inert no-op there.
        if let code = InlineCodeCopy.code(from: url) {
            copyInlineCode(code, url: url)
            return .handled
        }

        // Pure in-document anchor (`#heading`): no path, just a fragment.
        if (url.scheme == nil), url.path.isEmpty, let fragment = url.fragment {
            model.scrollToAnchor(fragment)
            return .handled
        }

        let isLocal = url.scheme == nil || url.scheme == "file"
        guard isLocal else { return .systemAction }

        let resolved = resolve(url)
        let ext = resolved.pathExtension.lowercased()
        if ["md", "markdown", "mdown"].contains(ext) {
            model.navigate(to: resolved)
            return .handled
        }
        // Non-Markdown local file (e.g. a linked .txt/.pdf/.png): reveal it in
        // Finder rather than replacing the reading view. Minimal, non-modal.
        if FileManager.default.fileExists(atPath: resolved.path) {
            NSWorkspace.shared.activateFileViewerSelecting([resolved])
            return .handled
        }
        return .systemAction
    }

    private func resolve(_ url: URL) -> URL {
        if url.scheme == "file" { return url.standardizedFileURL }
        if let base = documentURL {
            return base.deletingLastPathComponent()
                .appendingPathComponent(url.relativePath)
                .standardizedFileURL
        }
        return url.standardizedFileURL
    }
}

/// The small glass "Copied" pill that fades in near the top of the window
/// after a click-to-copy (Xcode-style, not a web toast). Isolated from the
/// reading view so its fade animation lives entirely in this subtree: reading
/// `pulse` off the injected feedback object re-shows it, but the parent's block
/// `LazyVStack` is never wrapped in the fade's animation transaction — the
/// reflow-on-click bug. Respects Reduce Motion by snapping instead of fading.
private struct CopyHUD: View {
    /// Bumped by the reading view on each copy; each bump re-shows. Read here
    /// (not passed down) so a copy never invalidates the reading `body`.
    @Environment(\.inlineCopyFeedback) private var feedback
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        Group {
            if visible {
                Label("Copied", systemImage: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(theme.chipStroke, lineWidth: 1))
                    .padding(.top, 14)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: feedback?.pulse) { _, _ in
            hideTask?.cancel()
            if reduceMotion { visible = true }
            else { withAnimation(Theme.Motion.feedback) { visible = true } }
            hideTask = Task {
                try? await Task.sleep(for: .seconds(1.0))
                guard !Task.isCancelled else { return }
                if reduceMotion { visible = false }
                else { withAnimation(Theme.Motion.stateExit) { visible = false } }
            }
        }
    }
}

/// One-time soft accent-tint fade for a block that just appeared/changed
/// via a watcher-driven live reload (PLAN §6: "a whisper, not a
/// highlight"). Applied per-row rather than inside `BlockView` itself so
/// the pulse stays purely a live-reload-time concern.
struct ChangePulseModifier: ViewModifier {
    let isPulsing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme
    @State private var opacity: Double = 0

    func body(content: Content) -> some View {
        content
            .background {
                // A rounded tint slightly inset from the block edges — a
                // whisper hugging the content, not a hard full-width band.
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.accent.opacity(opacity))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            }
            .onChange(of: isPulsing, initial: true) { _, newValue in
                guard newValue else { return }
                if reduceMotion {
                    // Reduce Motion: a static brief tint instead of a fade.
                    opacity = 0.14
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { opacity = 0 }
                } else {
                    opacity = 0.16
                    withAnimation(.easeOut(duration: 0.8)) { opacity = 0 }
                }
            }
    }
}
