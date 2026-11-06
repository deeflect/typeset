import AppKit
import MarcoCore
import MarcoRendering
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
            let source = try String(contentsOf: url, encoding: .utf8)
            try Task.checkCancellation()
            return try NativeMarkdownDocument.buildCancellable(
                source: source, blocks: MarkdownParser.parse(source), theme: theme, documentURL: url)
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
