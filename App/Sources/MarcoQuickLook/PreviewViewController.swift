import AppKit
import MarcoCore
import MarcoRendering
import Quartz
import SwiftUI

/// Quick Look preview extension: Space in Finder on a `.md` file renders it
/// with the exact same `MarcoRendering` block views and `Theme` the app uses
/// (PLAN §4 "pixel-identical", §2 J5). Deliberately static and read-only —
/// no file watcher, no editing, no interactive checkboxes/lightbox/find:
/// every interactive environment hook (`checkboxToggleHandler`,
/// `presentLightbox`, `findHighlight`) is left at its inert default, which is
/// exactly the posture those hooks were designed for (see their doc comments
/// in `MarcoRendering`).
final class PreviewViewController: NSViewController, @MainActor QLPreviewingController {
    override func loadView() {
        view = NSView()
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let blocks = MarkdownParser.parse(text)
            installHostingView(blocks: blocks, documentURL: url)
            handler(nil)
        } catch {
            handler(error)
        }
    }

    private func installHostingView(blocks: [Block], documentURL: URL) {
        let root = PreviewDocumentView(blocks: blocks, documentURL: documentURL)
        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let size = NSSize(width: 800, height: 900)
        view.setFrameSize(size)
        preferredContentSize = size
    }
}

/// The static reading surface: a plain scrolling column of `BlockView`s,
/// themed and light/dark aware via `.colorScheme` (`ScrollView` here is fine
/// — unlike the app's `ImageRenderer` snapshot path, Quick Look actually
/// hosts a live, scrollable `NSHostingView`).
private struct PreviewDocumentView: View {
    let blocks: [Block]
    let documentURL: URL
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("textScale") private var textScale: Double = 1.0

    private var theme: Theme { Theme(colorScheme: colorScheme, scale: CGFloat(textScale)) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(blocks) { block in
                    BlockView(block: block)
                        .id(block.id)
                }
            }
            .frame(maxWidth: theme.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, theme.contentHorizontalPadding)
            .padding(.top, theme.contentTopPadding)
            .padding(.bottom, theme.scaled(56))
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(theme.background)
        .environment(\.theme, theme)
        .environment(\.documentBaseURL, documentURL)
        // Every other rendering environment hook (checkbox write-back,
        // lightbox, find highlight) stays at its inert default — read-only,
        // static, exactly the Quick Look posture.
    }
}
