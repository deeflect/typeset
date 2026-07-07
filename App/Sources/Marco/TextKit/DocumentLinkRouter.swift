import AppKit
import MarcoCore
import MarcoRendering

/// The single link-routing policy for a reading surface, factored out of
/// `DocumentRenderer.handle(link:)` so the M6 TextKit 2 reading surface can
/// route clicks through the *same* decision tree instead of forking it. The
/// primitives it calls (`WindowModel.navigate`, `scrollToAnchor`,
/// `InlineCodeCopy`, `NSWorkspace`) are exactly the ones the shipping reading
/// view uses; only the dispatch site is shared here.
///
/// (`DocumentRenderer` still carries its own copy for now — converging it onto
/// this router is a clean, behavior-preserving follow-up. This slice does not
/// touch the shipping reading path.)
@MainActor
struct DocumentLinkRouter {
    var model: WindowModel
    var documentURL: URL?
    /// Copy an inline-code span to the pasteboard (and flash, if the surface
    /// wires one). Passed in because the flash state lives on the view.
    let copyInlineCode: (String, URL) -> Void

    /// Routes `url`. Returns `true` when handled in-app; `false` means the
    /// caller should defer to the system (open externally / ignore) — the
    /// same split `OpenURLAction.Result.handled` vs `.systemAction` encodes
    /// in `DocumentRenderer`.
    @discardableResult
    func route(_ url: URL) -> Bool {
        // Click-to-copy inline code (Telegram-style).
        if let code = InlineCodeCopy.code(from: url) {
            copyInlineCode(code, url)
            return true
        }
        // Pure in-document anchor (`#heading`): no path, just a fragment.
        if url.scheme == nil, url.path.isEmpty, let fragment = url.fragment {
            model.scrollToAnchor(fragment)
            return true
        }
        let isLocal = url.scheme == nil || url.scheme == "file"
        guard isLocal else { return false }

        let resolved = resolve(url)
        let ext = resolved.pathExtension.lowercased()
        if ["md", "markdown", "mdown"].contains(ext) {
            model.navigate(to: resolved)
            return true
        }
        if FileManager.default.fileExists(atPath: resolved.path) {
            NSWorkspace.shared.activateFileViewerSelecting([resolved])
            return true
        }
        return false
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
