import AppKit
import MarcoCore
import XCTest
@testable import Marco

@MainActor
final class AgentFeatureTests: XCTestCase {
    func testQuoteFormatsPathLinesAndQuotedText() {
        XCTAssertEqual(AgentQuote.format(path: "/p/PLAN.md", lines: 3...4, text: "one\n\ntwo\n"),
                       "`/p/PLAN.md:3-4`\n> one\n>\n> two")
        XCTAssertEqual(AgentQuote.format(path: "/p/a.md", lines: 42...42, text: "x"), "`/p/a.md:42`\n> x")
    }

    func testQuoteLinesFromBlocksAndEditorSelection() {
        let source = "---\ntitle: t\n---\n# Head\n\nline one\nline two\n\nlast\n"
        let blocks = MarkdownParser.parse(source)
        let offset = MarkdownParser.bodyLineOffset(in: source)
        let paragraph = blocks.first { $0.rawText.hasPrefix("line one") }!
        XCTAssertEqual(AgentQuote.lines(of: [paragraph], bodyLineOffset: offset), 6...7)
        XCTAssertEqual(AgentQuote.lines(of: [blocks.last!], bodyLineOffset: offset), 9...9)
        let text = source as NSString
        XCTAssertEqual(AgentQuote.lines(in: text, range: text.range(of: "line two\n")), 7...7)
        XCTAssertEqual(AgentQuote.lines(in: text, range: text.range(of: "one\nline")), 6...7)
    }

    func testLastViewedStoreRoundTripsAndKeepsNewest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("marco-viewed-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let store = LastViewedStore(directory: folder, limit: 2)
        let urls = (0..<3).map { URL(fileURLWithPath: "/tmp/doc\($0).md") }
        for (index, url) in urls.enumerated() {
            store.record(["id\(index)"], for: url)
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertNil(store.blockIDs(for: urls[0]))
        XCTAssertEqual(store.blockIDs(for: urls[2]), ["id2"])
    }

    /// RTF keeps the native table (AppKit's .docx writer flattened it). Images are dropped.
    func testRichTextExportKeepsTables() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("marco-rtf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemRed.setFill(); rect.fill(); return true
        }
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            .write(to: folder.appendingPathComponent("dot.png"))
        let doc = folder.appendingPathComponent("fixture.md")
        let source = "# Title\n\n| A | B |\n|---|---|\n| one | two |\n\n![dot](dot.png)\n\n```swift\nlet x = 1\n```\n"
        try Data(source.utf8).write(to: doc)
        let attributed = await PDFExporter.preparedDocument(source: source, url: doc)
        let rtf = String(decoding: try PDFExporter.richTextData(attributed), as: UTF8.self)
        XCTAssertTrue(rtf.hasPrefix("{\\rtf"))
        XCTAssertTrue(rtf.contains("\\trowd"), "table survives as an RTF table")
        XCTAssertTrue(rtf.contains("two"))
    }
}
