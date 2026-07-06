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
    @State private var copyToast = false
    @State private var copyToastTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(controller.blocks) { block in
                    BlockView(block: block)
                        .id(block.id)
                        .modifier(ChangePulseModifier(isPulsing: controller.pulsedBlockIDs.contains(block.id)))
                }
            }
            .scrollTargetLayout()
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
        .background(theme.background)
        .overlay(alignment: .top) { copyHUD }
        .environment(\.documentBaseURL, documentURL)
        // Zero cost when find is closed: `highlightContext` is nil, so block
        // views short-circuit all find work.
        .environment(\.findHighlight, model.find.highlightContext)
        .environment(\.openURL, OpenURLAction { url in handle(link: url) })
    }

    /// A small glass "Copied" pill that fades in near the top of the window
    /// after a click-to-copy on an inline-code span (Xcode-style, not a web
    /// toast). Respects Reduce Motion by snapping instead of fading.
    @ViewBuilder
    private var copyHUD: some View {
        if copyToast {
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

    /// Copy an inline-code span to the pasteboard and flash the HUD.
    private func copyInlineCode(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copyToastTask?.cancel()
        if reduceMotion {
            copyToast = true
        } else {
            withAnimation(.easeOut(duration: 0.18)) { copyToast = true }
        }
        copyToastTask = Task {
            try? await Task.sleep(for: .seconds(1.0))
            guard !Task.isCancelled else { return }
            if reduceMotion {
                copyToast = false
            } else {
                withAnimation(.easeOut(duration: 0.25)) { copyToast = false }
            }
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
            copyInlineCode(code)
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
