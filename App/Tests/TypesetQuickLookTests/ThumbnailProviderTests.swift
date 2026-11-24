import AppKit
import XCTest

@MainActor
final class ThumbnailProviderTests: XCTestCase {
    func testBoundedThumbnailReadCapsAt32KBAndStripsBOM() throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let shortURL = FileManager.default.temporaryDirectory.appendingPathComponent("typeset-thumb-short-\(UUID().uuidString).md")
        try (bom + Data("# Hello\n\nWorld\n".utf8)).write(to: shortURL)
        defer { try? FileManager.default.removeItem(at: shortURL) }
        XCTAssertEqual(try ThumbnailProvider.readThumbnailSource(shortURL), "# Hello\n\nWorld\n")

        let bigURL = FileManager.default.temporaryDirectory.appendingPathComponent("typeset-thumb-big-\(UUID().uuidString).md")
        let line = "This is a line of markdown prose for thumbnail truncation testing.\n"
        let repeated = String(repeating: line, count: 700)
        try Data(repeated.utf8).write(to: bigURL)
        defer { try? FileManager.default.removeItem(at: bigURL) }

        let read = try ThumbnailProvider.readThumbnailSource(bigURL)
        XCTAssertLessThanOrEqual(read.utf8.count, ThumbnailProvider.readLimit)
        XCTAssertTrue(read.hasPrefix("This is a line"))
    }

    func testThumbnailRendersNonEmptyImageForMarkdownAndEmptyFile() {
        let image = ThumbnailProvider.renderThumbnail(
            source: "# Release Notes\n\n- Native reader\n- Offline **Mermaid** & math\n",
            url: URL(fileURLWithPath: "/tmp/notes.md"),
            maximumSize: CGSize(width: 256, height: 256)
        )
        XCTAssertNotNil(image)
        XCTAssertGreaterThan(image?.width ?? 0, 100)
        XCTAssertGreaterThan(image?.height ?? 0, 100)

        let emptyImage = ThumbnailProvider.renderThumbnail(
            source: "",
            url: URL(fileURLWithPath: "/tmp/empty.md"),
            maximumSize: CGSize(width: 128, height: 128)
        )
        XCTAssertNotNil(emptyImage)
    }
}
