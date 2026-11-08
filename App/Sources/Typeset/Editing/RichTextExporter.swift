import AppKit
import TypesetCore
import TypesetRendering

@MainActor
enum RichTextExporter {
    private static var copyGeneration = 0
    private static var buildTask: Task<NativeMarkdownDocument, Error>?

    static func copyLiveSource(_ source: String, theme: Theme, url: URL?, pasteboard: NSPasteboard = .general) {
        copyGeneration += 1
        let generation = copyGeneration
        buildTask?.cancel()
        pasteboard.clearContents()
        pasteboard.setString(source, forType: .string)
        let initialChangeCount = pasteboard.changeCount
        let task = Task.detached(priority: .userInitiated) {
            try NativeMarkdownDocument.buildCancellable(
                source: source, blocks: MarkdownParser.parse(source, mdx: MarkdownParser.isMDX(url)), theme: theme, documentURL: url)
        }
        buildTask = task
        Task {
            guard let snapshot = try? await task.value else { return }
            let attributed = await snapshot.withLoadedLocalImages()
            guard generation == copyGeneration, pasteboard.changeCount == initialChangeCount else { return }
            let range = NSRange(location: 0, length: attributed.length)
            var expected = initialChangeCount
            for (kind, type) in [
                (NSAttributedString.DocumentType.rtfd, NSPasteboard.PasteboardType.rtfd),
                (.rtf, .rtf), (.html, .html)
            ] {
                guard pasteboard.changeCount == expected else { return }
                if let data = try? attributed.data(from: range, documentAttributes: [.documentType: kind]) {
                    pasteboard.setData(data, forType: type)
                    expected = pasteboard.changeCount
                }
            }
        }
    }
}
