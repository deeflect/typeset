import AppKit
import MarcoCore
import MarcoRendering
import UniformTypeIdentifiers

/// PDF and print share the native attributed document, including tables and images.
@MainActor
enum PDFExporter {
    static func exportPDF(source: String, url: URL?, suggestedName: String) {
        Task {
            let attributed = await preparedDocument(source: source, url: url)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = suggestedName
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            run(attributed: attributed, savingTo: destination)
        }
    }

    /// Same document as PDF/rich copy, written by AppKit's Office Open XML writer.
    static func exportWord(source: String, url: URL?, suggestedName: String) {
        Task {
            let attributed = await preparedDocument(source: source, url: url)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "docx")].compactMap { $0 }
            panel.nameFieldStringValue = suggestedName
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            do {
                try wordData(attributed).write(to: destination, options: .atomic)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    static func wordData(_ attributed: NSAttributedString) throws -> Data {
        try attributed.data(from: NSRange(location: 0, length: attributed.length),
                            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    }

    static func print(source: String, url: URL?) {
        Task {
            let attributed = await preparedDocument(source: source, url: url)
            run(attributed: attributed, savingTo: nil)
        }
    }

    static func preparedDocument(source: String, url: URL?) async -> NSAttributedString {
        let theme = Theme(colorScheme: .light, scale: 1)
        let snapshot = await Task.detached(priority: .userInitiated) {
            NativeMarkdownDocument.build(
                source: source, blocks: MarkdownParser.parse(source), theme: theme,
                documentURL: url, metadataExpanded: false)
        }.value
        return await snapshot.withLoadedLocalImages()
    }

    @discardableResult
    static func run(attributed: NSAttributedString, savingTo destination: URL?) -> Bool {
        guard let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo else { return false }
        printInfo.topMargin = 54
        printInfo.bottomMargin = 54
        printInfo.leftMargin = 54
        printInfo.rightMargin = 54
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        if let destination {
            printInfo.dictionary()[NSPrintInfo.AttributeKey.jobDisposition] = NSPrintInfo.JobDisposition.save.rawValue
            printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = destination
        }

        let pageWidth = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: pageWidth, height: 100))
        textView.textContainerInset = .zero
        textView.isEditable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: pageWidth, height: .greatestFiniteMagnitude)
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: pageWidth, height: .greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(attributed)
        if let container = textView.textContainer, let layoutManager = textView.layoutManager {
            layoutManager.ensureLayout(for: container)
            textView.setFrameSize(NSSize(width: pageWidth, height: layoutManager.usedRect(for: container).height))
        }

        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.showsProgressPanel = false
        if destination != nil {
            operation.showsPrintPanel = false
        } else {
            operation.showsPrintPanel = true
        }
        return operation.run()
    }
}
