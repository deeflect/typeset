import AppKit
import MarcoCore
import UniformTypeIdentifiers
import MarcoRendering

/// PLAN §2 J5: Export PDF (⌘⇧E) and Print (⌘P), sharing one path so both
/// use the same reading-theme (light variant) rendering. Paginates via an
/// offscreen `NSTextView` driving `NSPrintOperation` rather than
/// `ImageRenderer`, since `NSPrintOperation`'s own text pagination yields
/// real, selectable PDF text (an `ImageRenderer`/`NSGraphicsContext`
/// rasterization would flatten it to pixels).
@MainActor
enum PDFExporter {
    static func exportPDF(blocks: [Block], suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run(blocks: blocks, savingTo: url)
    }

    static func print(blocks: [Block]) {
        run(blocks: blocks, savingTo: nil)
    }

    private static func run(blocks: [Block], savingTo url: URL?) {
        // Light variant per PLAN §2 J5, regardless of the window's current
        // appearance — exports/prints should look like a document, not
        // match whatever the reader happened to be in.
        let theme = Theme(colorScheme: .light, scale: 1)
        let attributed = RichTextExporter.build(blocks: blocks, theme: theme)

        guard let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) else { return }
        printInfo.topMargin = 54
        printInfo.bottomMargin = 54
        printInfo.leftMargin = 54
        printInfo.rightMargin = 54
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic

        let pageWidth = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: pageWidth, height: 100))
        textView.textContainerInset = .zero
        textView.isEditable = false
        textView.textStorage?.setAttributedString(attributed)

        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.showsProgressPanel = false

        if let url {
            operation.showsPrintPanel = false
            printInfo.dictionary()[NSPrintInfo.AttributeKey.jobDisposition] = NSPrintInfo.JobDisposition.save.rawValue
            printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        } else {
            operation.showsPrintPanel = true
        }
        operation.run()
    }
}
