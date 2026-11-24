import AppKit
import TypesetCore
import TypesetRendering
import Quartz
import SwiftUI

/// Quick Look uses the same rendered document and reading view as the app.
final class PreviewViewController: NSViewController, @MainActor QLPreviewingController {
    private var generation = 0
    private var currentURL: URL?
    private var preparationTask: Task<NativeMarkdownDocument, Error>?
    private var isPreparing = false
    private var needsAppearanceRefresh = false
    private(set) var installedColorScheme: ColorScheme?
    private(set) var installationCount = 0

    override func loadView() {
        let host = AppearanceView()
        host.onChange = { [weak self] in
            guard let self, let url = self.currentURL else { return }
            if self.isPreparing { self.needsAppearanceRefresh = true; return }
            self.preparePreviewOfFile(at: url) { _ in }
        }
        view = host
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        generation += 1
        preparationTask?.cancel()
        isPreparing = false
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        generation += 1
        let requested = generation
        currentURL = url
        preparationTask?.cancel()
        isPreparing = true
        view.subviews.forEach { $0.removeFromSuperview() }
        installedColorScheme = nil
        let appearance = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? ColorScheme.dark : .light
        let theme = Theme(colorScheme: appearance, scale: 1)
        let task = Task.detached(priority: .userInitiated) {
            let source = try Self.readCappedSource(url).text
            try Task.checkCancellation()
            let parsed = MarkdownParser.parseDocument(source, mdx: MarkdownParser.isMDX(url))
            return try NativeMarkdownDocument.buildCancellable(
                source: source, blocks: parsed.blocks, document: parsed.document, theme: theme, documentURL: url)
        }
        preparationTask = task
        Task { @MainActor in
            let result = await task.result
            guard requested == generation else { handler(CancellationError()); return }
            isPreparing = false
            switch result {
            case .success(let snapshot):
                install(snapshot, theme: theme)
                handler(nil)
            case .failure(let error):
                handler(error)
            }
            if needsAppearanceRefresh {
                needsAppearanceRefresh = false
                preparePreviewOfFile(at: url) { _ in }
            }
        }
    }

    /// Quick Look renders at most this much source; past it the preview
    /// stops at the last line break and says so.
    nonisolated static let previewLimit = 2 * 1024 * 1024

    nonisolated static func capped(_ text: String, limit: Int = previewLimit) -> String {
        let utf8 = text.utf8
        guard utf8.count > limit else { return text }
        let head = utf8.prefix(limit)
        let cut = head.lastIndex(of: UInt8(ascii: "\n")).map { head[..<$0] } ?? head
        return String(decoding: cut, as: UTF8.self)
            + "\n\n---\n\n*Preview shows the first 2 MB. Open in Typeset for the full file.*\n"
    }

    nonisolated static func readCappedSource(_ url: URL, limit: Int = previewLimit) throws -> (text: String, bytesRead: Int) {
        let handle = try FileHandle(forReadingFrom: url.resolvingSymlinksInPath())
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(limit + 4) // UTF-8 BOM plus one byte beyond the text cap.
        while data.count < limit + 4 {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: limit + 4 - data.count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        try Task.checkCancellation()
        let bytesRead = data.count
        let bytes = data.dropFirst(data.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0)
        guard bytes.count > limit else {
            guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            return (text, bytesRead)
        }
        let head = bytes.prefix(limit)
        let newline = head.lastIndex(of: UInt8(ascii: "\n"))
        let cut = newline.map { head[..<$0] } ?? head
        if String(validating: cut, as: UTF8.self) == nil {
            // A valid scalar may cross the cap; the old lossy cap shows its replacement character.
            guard newline == nil, (1..<min(4, cut.count + 1)).contains(where: { count in
                let tail = Array(cut.suffix(count))
                let first = tail[0]
                let width = (0xC2...0xDF).contains(first) ? 2 : (0xE0...0xEF).contains(first) ? 3 : (0xF0...0xF4).contains(first) ? 4 : 0
                guard width > count, String(validating: cut.dropLast(count), as: UTF8.self) != nil else { return false }
                guard tail.dropFirst().allSatisfy({ (0x80...0xBF).contains($0) }) else { return false }
                if count > 1 {
                    let second = tail[1]
                    guard (first != 0xE0 || second >= 0xA0), (first != 0xED || second <= 0x9F),
                          (first != 0xF0 || second >= 0x90), (first != 0xF4 || second <= 0x8F) else { return false }
                }
                return true
            }) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        }
        return (String(decoding: cut, as: UTF8.self)
                + "\n\n---\n\n*Preview shows the first 2 MB. Open in Typeset for the full file.*\n", bytesRead)
    }

    private func install(_ document: NativeMarkdownDocument, theme: Theme) {
        installedColorScheme = theme.colorScheme
        installationCount += 1
        view.subviews.forEach { $0.removeFromSuperview() }
        let hosting = NSHostingView(rootView: NativeMarkdownReadingView(
            document: document, theme: theme, controller: NativeMarkdownReadingView.Controller()))
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

private final class AppearanceView: NSView {
    var onChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onChange?()
    }
}
