import MarcoCore
import SwiftUI

extension Notification.Name {
    /// Posted when a relative Markdown link is clicked. M1 stub — the
    /// in-window navigation handler (back/forward) lands in a later
    /// milestone.
    static let marcoNavigateToMarkdown = Notification.Name("marcoNavigateToMarkdown")
}

/// The reading surface: a `LazyVStack` of per-block views inside a
/// `ScrollView`, keyed by `block.id` so virtualization holds on large
/// documents and unchanged blocks are reused on reload. Prose is capped to
/// the reading measure and centered; the content layer is opaque so glass
/// only ever sits on chrome.
struct DocumentRenderer: View {
    @Bindable var controller: DocumentReloadController
    let documentURL: URL?
    @Environment(\.theme) private var theme

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
        }
        .scrollPosition($controller.scrollPosition)
        .background(theme.background)
        .environment(\.documentBaseURL, documentURL)
        .environment(\.openURL, OpenURLAction { url in handle(link: url) })
    }

    private func handle(link url: URL) -> OpenURLAction.Result {
        let isLocal = url.scheme == nil || url.scheme == "file"
        let isMarkdown = ["md", "markdown", "mdown"].contains(url.pathExtension.lowercased())
        if isLocal && isMarkdown {
            // Stub: real in-window navigation (with back/forward) is a
            // later milestone. Resolve against the document directory so
            // the eventual handler receives an absolute URL.
            let resolved: URL
            if url.scheme == "file" {
                resolved = url
            } else if let base = documentURL {
                resolved = base.deletingLastPathComponent().appendingPathComponent(url.relativePath).standardizedFileURL
            } else {
                resolved = url
            }
            NotificationCenter.default.post(name: .marcoNavigateToMarkdown, object: resolved)
            return .handled
        }
        return .systemAction
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
            .background(theme.accent.opacity(opacity))
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
