import AppKit
import TypesetCore
import SwiftUI
import XCTest
@testable import TypesetRendering

final class NativeMarkdownDocumentTests: XCTestCase {
    @MainActor func testReaderConsumesLinksAndRestrictsExternalSchemes() {
        var routed: [URL] = []
        var opened: [URL] = []
        let callback: (URL) -> Bool = { routed.append($0); return false }
        let external: (URL) -> Bool = { opened.append($0); return true }
        let handle = NativeMarkdownReadingView.Coordinator.handleLink

        for source in ["javascript:alert(1)", "data:text/plain,hello", "x-custom:launch"] {
            XCTAssertTrue(handle(URL(string: source)!, callback, external))
        }
        XCTAssertTrue(routed.isEmpty)
        XCTAssertTrue(opened.isEmpty)

        let file = URL(fileURLWithPath: "/tmp/next.md")
        XCTAssertTrue(handle(file, callback, external))
        XCTAssertEqual(routed, [file])
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(handle(file, nil, external))
        XCTAssertTrue(opened.isEmpty)

        for source in ["https://example.com", "http://example.com", "mailto:hello@example.com"] {
            XCTAssertTrue(handle(URL(string: source)!, callback, external))
        }
        XCTAssertEqual(opened.count, 3)
        XCTAssertEqual(routed.count, 4)
        XCTAssertTrue(handle(URL(string: "https://example.com")!, { _ in true }, external))
        XCTAssertEqual(opened.count, 3)
    }

    func testRepeatedSmallFencesRecordOnlyTheirOwnRanges() {
        let source = (0..<600).map { "```swift\nlet n = \($0)\n```\n" }.joined(separator: "\n")
        let blocks = MarkdownParser.parse(source)
        let started = CFAbsoluteTimeGetCurrent()
        let rendered = NativeMarkdownDocument.build(source: source, blocks: blocks,
            theme: Theme(colorScheme: .light, scale: 1), documentURL: nil)
        print("NATIVE_FENCES_BENCH count=600 build_ms=\(Int((CFAbsoluteTimeGetCurrent() - started) * 1000))")
        XCTAssertEqual(rendered.codeRanges.count, 600)
        XCTAssertEqual(rendered.blockRanges.count, 600)
        XCTAssertTrue(rendered.blockRanges.allSatisfy { $0.marks == ["code:swift"] })
    }

    @MainActor func testMaterializedSliceKeepsAttachmentOffsets() {
        let source = "- [x] Task\n\n![alt](pic.png)\n"
        let document = NativeMarkdownDocument.build(source: source, blocks: MarkdownParser.parse(source),
            theme: Theme(colorScheme: .light, scale: 1), documentURL: nil)
        let full = document.materializedAttributedString()
        let imageRange = document.blockRanges.last!.range
        let slice = document.materializedAttributedString(in: imageRange)
        XCTAssertEqual(slice.string, full.attributedSubstring(from: imageRange).string)
        let imageOffset = document.images[0].range.location - imageRange.location
        XCTAssertTrue((slice.attribute(.attachment, at: imageOffset, effectiveRange: nil) as? NSTextAttachment)?.attachmentCell is ImagePlaceholderCell)
        XCTAssertEqual(slice.string.components(separatedBy: "\u{FFFC}").count - 1, 1)
    }

    func testMDXHidesESMAndRendersContainerChildren() {
        let source = """
        ---
        title: Post
        ---
        import { Callout } from './c'

        Hello {props.name}

        <Callout type="warn">
        Inside **bold**
        </Callout>

        <Chart
          data={[1]}
        />

        <kbd>K</kbd>
        """
        let url = URL(fileURLWithPath: "/tmp/post.mdx")
        let blocks = MarkdownParser.parse(source, mdx: true)
        let doc = NativeMarkdownDocument.build(source: source, blocks: blocks,
            theme: Theme(colorScheme: .light, scale: 1), documentURL: url)
        let text = doc.attributedString.string
        XCTAssertFalse(text.contains("from './c'"))
        XCTAssertTrue(text.contains("1 import\n"))
        let inside = (text as NSString).range(of: "Inside bold\n")
        XCTAssertNotEqual(inside.location, NSNotFound)
        XCTAssertFalse(text.contains("</Callout>"))
        let frame = (doc.attributedString.attribute(.paragraphStyle, at: inside.location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.first
        XCTAssertNotNil(frame as? TypesetTextBlock)
        XCTAssertTrue(text.contains("\u{FFFC} <Chart data={[1]} />\n"))
        XCTAssertFalse(text.contains("<kbd>"))
        let expression = (text as NSString).range(of: "{props.name}")
        let font = doc.attributedString.attribute(.font, at: expression.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.isFixedPitch == true)
        // Every parsed block except the frontmatter maps to a rendered range.
        XCTAssertEqual(doc.blockRanges.count, blocks.count)
        // The same text as .md keeps the old path.
        let md = NativeMarkdownDocument.build(source: source, blocks: MarkdownParser.parse(source),
            theme: Theme(colorScheme: .light, scale: 1), documentURL: URL(fileURLWithPath: "/tmp/post.md"))
        XCTAssertTrue(md.attributedString.string.contains("import"))
    }

    func testFullDocumentReferencesTasksAndTables() {
        let source = """
        ---
        title: Sample
        ---
        # Heading
        [reference][id]

        [id]: https://example.com

        - [ ] Task
          - [x] Nested

        | Left | Right |
        | :--- | ---: |
        | **bold** | `a\\|b` |
        """
        let rendered = NativeMarkdownDocument.build(source: source, blocks: MarkdownParser.parse(source), theme: Theme(colorScheme: .light, scale: 1), documentURL: nil)
        XCTAssertTrue(rendered.attributedString.string.contains("reference"))
        XCTAssertTrue(rendered.attributedString.string.contains("a|b"))
        XCTAssertFalse(rendered.attributedString.string.contains("[id]"))
        XCTAssertEqual(rendered.checkboxes.count, 2)
        XCTAssertEqual(rendered.checkboxes.map(\.lineOffset), [0, 1])
        var tableCellCount = 0
        rendered.attributedString.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rendered.attributedString.length)) { value, _, _ in
            if (value as? NSParagraphStyle)?.textBlocks.first is NSTextTableBlock { tableCellCount += 1 }
        }
        XCTAssertGreaterThanOrEqual(tableCellCount, 4)
    }
}

extension NativeMarkdownDocumentTests {
    func testResolvedLinksImagesHTMLAndAppearance() {
        let source = """
        # **Bold** *italic* ~~gone~~
        [local](other%20file.md#part) [section](#hello) [remote](https://example.com/a%20b)
        ![Preview](assets/my%20image.png)
        <script>alert('literal')</script>
        `inline` and **strong**
        """
        let file = URL(fileURLWithPath: "/tmp/docs/readme.md")
        let light = NativeMarkdownDocument.build(source: source, blocks: MarkdownParser.parse(source), theme: Theme(colorScheme: .light, scale: 1), documentURL: file)
        let dark = NativeMarkdownDocument.build(source: source, blocks: MarkdownParser.parse(source), theme: Theme(colorScheme: .dark, scale: 1.4), documentURL: file)
        let plain = light.attributedString.string
        XCTAssertTrue(plain.contains("Bold italic gone"))
        XCTAssertTrue(plain.contains("<script>alert('literal')</script>"))
        XCTAssertFalse(plain.contains("~~gone~~"))
        XCTAssertFalse(plain.contains("my%20image.png"))
        XCTAssertEqual(light.images.first?.url?.path, "/tmp/docs/assets/my image.png")
        XCTAssertEqual(light.images.first?.alt, "Preview")
        let local = (light.attributedString.attribute(.link, at: (plain as NSString).range(of: "local").location, effectiveRange: nil) as? URL)
        let section = (light.attributedString.attribute(.link, at: (plain as NSString).range(of: "section").location, effectiveRange: nil) as? URL)
        XCTAssertEqual(local?.fragment, "part")
        XCTAssertEqual(local?.path, "/tmp/docs/other file.md")
        XCTAssertEqual(section?.fragment, "hello")
        XCTAssertEqual(section?.path, file.path)
        let lightFont = light.attributedString.attribute(.font, at: 1, effectiveRange: nil) as? NSFont
        let darkFont = dark.attributedString.attribute(.font, at: 1, effectiveRange: nil) as? NSFont
        XCTAssertTrue((darkFont?.pointSize ?? 0) > (lightFont?.pointSize ?? .infinity))
    }

    func testTableCellsAndTaskSourceLines() {
        let source = """
        ---
        title: T
        ---
        - [ ] First
          - [x] Second

        | Left | Right |
        | :--- | ---: |
        | A | B |
        | C | D |
        """
        let rendered = NativeMarkdownDocument.build(source: source, blocks: MarkdownParser.parse(source), theme: Theme(colorScheme: .light, scale: 1), documentURL: nil)
        XCTAssertEqual(rendered.checkboxes.map { $0.blockStartLine + $0.lineOffset }, [0, 1])
        XCTAssertEqual(rendered.blockRanges.first?.sourceLine, -1)
        let text = rendered.attributedString.string as NSString
        for (cell, row, column) in [("Left", 0, 0), ("Right", 0, 1), ("A", 1, 0), ("B", 1, 1), ("C", 2, 0), ("D", 2, 1)] {
            let index = text.range(of: cell).location
            let paragraph = rendered.attributedString.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
            let block = paragraph?.textBlocks.first as? NSTextTableBlock
            XCTAssertEqual(block?.startingRow, row)
            XCTAssertEqual(block?.startingColumn, column)
        }
        let right = text.range(of: "Right").location
        let alignment = (rendered.attributedString.attribute(.paragraphStyle, at: right, effectiveRange: nil) as? NSParagraphStyle)?.alignment
        XCTAssertEqual(alignment, .right)
    }
}

extension NativeMarkdownDocumentTests {
    func testNestedFontTraitsAndLinkedImage() {
        let source = "**bold *both* text** [![Preview](pic.png)](target.md)"
        let file = URL(fileURLWithPath: "/tmp/docs/readme.md")
        let rendered = NativeMarkdownDocument.build(source: source, blocks: MarkdownParser.parse(source), theme: Theme(colorScheme: .light, scale: 1), documentURL: file)
        let text = rendered.attributedString.string as NSString
        let index = text.range(of: "both").location
        let traits = (rendered.attributedString.attribute(.font, at: index, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits
        XCTAssertTrue(traits?.contains(.bold) == true)
        XCTAssertTrue(traits?.contains(.italic) == true)
        guard let image = rendered.images.first else { return XCTFail("missing image") }
        XCTAssertEqual(image.range.length, 1)
        XCTAssertEqual(text.substring(with: image.range), "\u{FFFC}")
        let link = rendered.attributedString.attribute(.link, at: image.range.location, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.path, "/tmp/docs/target.md")
        XCTAssertEqual(image.url?.path, "/tmp/docs/pic.png")
    }

    @MainActor func testLocalImageExportKeepsOffsets() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("pic.png"))
        let source = "Before ![alt](pic.png) After"
        let doc = NativeMarkdownDocument.build(source: source, blocks: MarkdownParser.parse(source), theme: Theme(colorScheme: .light, scale: 1), documentURL: directory.appendingPathComponent("readme.md"))
        let loaded = await doc.withLoadedLocalImages()
        XCTAssertEqual(loaded.string, doc.attributedString.string)
        let index = doc.images[0].range.location
        let attachment = loaded.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment
        XCTAssertNotNil((attachment?.attachmentCell as? NSTextAttachmentCell)?.image)
        let rtfd = try loaded.data(from: NSRange(location: 0, length: loaded.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let roundTrip = try NSAttributedString(data: rtfd, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
        let restored = roundTrip.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment
        XCTAssertNotNil(restored?.fileWrapper)
        let narrow = NativeMarkdownImages.attachment(for: await NativeMarkdownImages.load(directory.appendingPathComponent("pic.png")), maxWidth: 1, isDark: false)
        XCTAssertLessThanOrEqual((narrow.attachmentCell as? NSTextAttachmentCell)?.image?.size.width ?? .infinity, 1)
        XCTAssertNotNil(narrow.fileWrapper?.regularFileContents)
    }
}

extension NativeMarkdownDocumentTests {
    func testNativeHighlighterCarriesAppKitColorsWithoutFont() async {
        guard let highlighted = await CodeHighlighter.shared.highlightedNative(code: "let answer = 42", language: "swift", isDark: false) else {
            return XCTFail("highlighting unavailable")
        }
        var colored = false
        highlighted.enumerateAttributes(in: NSRange(location: 0, length: highlighted.length)) { attributes, _, _ in
            colored = colored || attributes[.foregroundColor] is NSColor
            XCTAssertNil(attributes[.font])
        }
        XCTAssertTrue(colored)
        if let comment = await CodeHighlighter.shared.highlightedNative(code: "// comment", language: "swift", isDark: true),
           let color = comment.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
           let rgb = color.usingColorSpace(.deviceRGB) {
            func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            let foreground = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
            let background = linear(0.13)
            XCTAssertGreaterThanOrEqual((foreground + 0.05) / (background + 0.05), 4.5)
        } else {
            XCTFail("dark comment color unavailable")
        }
    }
}

extension NativeMarkdownDocumentTests {
    @MainActor func testTextKitTableLayoutAndProbeImage() throws {
        let source = """
        # Render probe
        Paragraph with **bold**, *italic*, [link](https://example.com), and `code`.

        | Name | Value | Notes |
        | :--- | ---: | :---: |
        | Alpha | 42 | `a\\|b` |
        | Beta | 100 | extra |

        ```swift
        let veryLongIdentifierWithoutAnySpaces0123456789012345678901234567890123456789012345678901234567890 = 1
        ```
        """
        let document = NativeMarkdownDocument.build(source: source, blocks: MarkdownParser.parse(source), theme: Theme(colorScheme: .light, scale: 1), documentURL: nil)
        let storage = NSTextStorage(attributedString: document.attributedString)
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 500), textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        XCTAssertGreaterThan(used.height, 0)
        XCTAssertLessThanOrEqual(used.width, 410)
        view.frame.size.height = max(500, used.height)
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/typeset-native-renderer-probe.png"))
        }
    }
}

extension NativeMarkdownDocumentTests {
    @MainActor func testBenchmarkWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["TYPESET_NATIVE_BENCH"] == "1" else { throw XCTSkip("one-shot benchmark") }
        let section = "# Heading\nParagraph with **bold**, [link](https://example.com), and `code`.\n\n| Left | Right |\n| :--- | ---: |\n| A | 42 |\n\n"
        let prose = "# Heading\nParagraph with **bold**, *italic*, and [link](https://example.com). This is normal wrapped prose in a reading document.\n\n"
        // TYPESET_NATIVE_BENCH_FILES=a.md:b.md benchmarks those files instead (thread CPU time too).
        let files = ProcessInfo.processInfo.environment["TYPESET_NATIVE_BENCH_FILES"]?.split(separator: ":").map(String.init) ?? []
        let cases = files.isEmpty ? [
            ("tables-small", String(repeating: section, count: 100)),
            ("tables-large", String(repeating: section, count: 10000)),
            ("prose-50k", String(repeating: prose, count: 500)),
            ("prose-1m", String(repeating: prose, count: 10000))
        ] : try files.map { (URL(fileURLWithPath: $0).lastPathComponent, try String(contentsOfFile: $0, encoding: .utf8)) }
        func cpu() -> Double { var t = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t); return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9 }
        for (kind, source) in cases {
            let cpuStart = cpu()
            let start = CFAbsoluteTimeGetCurrent()
            let (blocks, parsedDocument) = MarkdownParser.parseDocument(source)
            let parsed = CFAbsoluteTimeGetCurrent()
            let theme = Theme(colorScheme: .light, scale: 1)
            let first = NativeMarkdownDocument.build(source: source, blocks: blocks, document: parsedDocument, theme: theme, documentURL: nil)
            let built = CFAbsoluteTimeGetCurrent()
            let cpuBuilt = cpu()
            let storage = NSTextStorage(attributedString: first.attributedString)
            let installed = CFAbsoluteTimeGetCurrent()
            let layout = NSLayoutManager()
            layout.allowsNonContiguousLayout = true
            storage.addLayoutManager(layout)
            let container = NSTextContainer(size: NSSize(width: 720, height: CGFloat.greatestFiniteMagnitude))
            layout.addTextContainer(container)
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: 0, length: min(1000, storage.length)), actualCharacterRange: nil)
            _ = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let visible = CFAbsoluteTimeGetCurrent()
            let updated = source + "Tail\n"
            let reparsed = MarkdownParser.parseDocument(updated); let changed = NativeMarkdownDocument.build(source: updated, blocks: reparsed.blocks, document: reparsed.document, theme: theme, documentURL: nil)
            let rebuilt = CFAbsoluteTimeGetCurrent()
            let splice = changed.replacementRanges(from: first)
            storage.replaceCharacters(in: splice.old, with: changed.attributedString.attributedSubstring(from: splice.new))
            let reinstalled = CFAbsoluteTimeGetCurrent()
            print("NATIVE_BENCH kind=\(kind) bytes=\(source.utf8.count) parse_ms=\(Int((parsed-start)*1000)) build_ms=\(Int((built-parsed)*1000)) install_ms=\(Int((installed-built)*1000)) visible_ms=\(Int((visible-installed)*1000)) reload_build_ms=\(Int((rebuilt-visible)*1000)) reload_install_ms=\(Int((reinstalled-rebuilt)*1000)) parse_build_cpu_ms=\(Int((cpuBuilt-cpuStart)*1000))")
        }
    }
}

extension NativeMarkdownDocumentTests {
    func testReloadSpliceTracksReferenceDestinationAndAppendedTail() {
        let theme = Theme(colorScheme: .light, scale: 1)
        let firstSource = "[same][ref]\n\n[ref]: https://example.com/one\n"
        let secondSource = "[same][ref]\n\n[ref]: https://example.com/two\n"
        let first = NativeMarkdownDocument.build(source: firstSource, blocks: MarkdownParser.parse(firstSource), theme: theme, documentURL: nil)
        let second = NativeMarkdownDocument.build(source: secondSource, blocks: MarkdownParser.parse(secondSource), theme: theme, documentURL: nil)
        let changedLink = second.replacementRanges(from: first)
        XCTAssertGreaterThan(changedLink.old.length, 0)
        let updated = NSMutableAttributedString(attributedString: first.attributedString)
        updated.replaceCharacters(in: changedLink.old, with: second.attributedString.attributedSubstring(from: changedLink.new))
        let link = updated.attribute(.link, at: 0, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.absoluteString, "https://example.com/two")

        let tailSource = firstSource + "Tail\n"
        let tail = NativeMarkdownDocument.build(source: tailSource, blocks: MarkdownParser.parse(tailSource), theme: theme, documentURL: nil)
        let changedTail = tail.replacementRanges(from: first)
        XCTAssertLessThan(changedTail.old.length, first.attributedString.length)
        updated.setAttributedString(first.attributedString)
        updated.replaceCharacters(in: changedTail.old, with: tail.attributedString.attributedSubstring(from: changedTail.new))
        XCTAssertEqual(updated.string, tail.attributedString.string)
    }
}

extension NativeMarkdownDocumentTests {
    func testImageReferenceChangeForcesSplice() {
        let theme = Theme(colorScheme: .light, scale: 1)
        let url = URL(fileURLWithPath: "/tmp/doc.md")
        let firstSource = "![alt][pic]\n\n[pic]: one.png\n"
        let secondSource = "![alt][pic]\n\n[pic]: two.png\n"
        let first = NativeMarkdownDocument.build(source: firstSource, blocks: MarkdownParser.parse(firstSource), theme: theme, documentURL: url)
        let second = NativeMarkdownDocument.build(source: secondSource, blocks: MarkdownParser.parse(secondSource), theme: theme, documentURL: url)
        XCTAssertEqual(first.images.first?.url?.lastPathComponent, "one.png")
        XCTAssertEqual(second.images.first?.url?.lastPathComponent, "two.png")
        XCTAssertGreaterThan(second.replacementRanges(from: first).old.length, 0)
    }

    func testMetadataCanCollapseWithoutLeakingRawFence() {
        let source = "---\ntitle: Sample\n---\n# Heading"
        let blocks = MarkdownParser.parse(source)
        let theme = Theme(colorScheme: .light, scale: 1)
        let open = NativeMarkdownDocument.build(source: source, blocks: blocks, theme: theme, documentURL: nil)
        let closed = NativeMarkdownDocument.build(source: source, blocks: blocks, theme: theme, documentURL: nil, metadataExpanded: false)
        XCTAssertTrue(open.attributedString.string.contains("title\tSample"))
        XCTAssertFalse(closed.attributedString.string.contains("title\tSample"))
        XCTAssertFalse(open.attributedString.string.contains("---"))
        XCTAssertTrue(closed.attributedString.string.contains("Heading"))
    }

    func testReaderStatesPortedFromBoards() {
        let theme = Theme(colorScheme: .light, scale: 1)
        func build(_ source: String, mdx: Bool = false, expanded: Set<String>? = nil) -> NSAttributedString {
            NativeMarkdownDocument.build(source: source, blocks: MarkdownParser.parse(source, mdx: mdx), theme: theme,
                                         documentURL: URL(fileURLWithPath: mdx ? "/tmp/x.mdx" : "/tmp/x.md"), expanded: expanded).attributedString
        }
        // R08: collapsed summary row, toggle key only when interactive.
        let fm = build("---\ndate: 2026-11-05\nauthor: Dee\ntags: [a, b, c, d]\nslug: x-y\n---\nBody", expanded: [])
        XCTAssertTrue(fm.string.contains("Dee"))
        XCTAssertTrue(fm.string.contains("+1"))
        XCTAssertFalse(fm.string.contains("slug\t"))
        XCTAssertEqual(fm.attribute(.typesetMetadata, at: 0, effectiveRange: nil) as? String, "metadata")
        XCTAssertTrue(build("---\nslug: x-y\n---\nBody", expanded: ["metadata"]).string.contains("slug\tx-y"))
        XCTAssertTrue(build("---\ntags: [a\n---\nBody", expanded: ["metadata"]).string.contains("unclosed ["))
        // R08: description once when open; a title equal to the leading H1 stays out of the summary row.
        let lead = build("---\ntitle: Plan\ndescription: Ship it.\n---\n# Plan", expanded: ["metadata"]).string
        XCTAssertEqual(lead.components(separatedBy: "Ship it.").count - 1, 1)
        XCTAssertFalse(lead.components(separatedBy: "\n").first!.contains("Plan"))
        XCTAssertTrue(build("---\ntitle: Plan\ndescription: Ship it.\n---\n# Plan", expanded: []).string.contains("Ship it."))
        // R04: <details> without `open` starts collapsed when interactive; static renders open.
        let details = "<details>\n<summary>More</summary>\n\nHidden body\n\n</details>\n\nAfter"
        XCTAssertFalse(build(details, expanded: []).string.contains("Hidden body"))
        XCTAssertTrue(build(details, expanded: ["details:More"]).string.contains("Hidden body"))
        XCTAssertTrue(build(details).string.contains("Hidden body"))
        XCTAssertTrue(build(details, expanded: []).string.contains("After"))
        // R09: ESM collapses to one row.
        let mdx = build("import A from './a'\nimport B from './b'\nexport const x = 1\n\n# Title", mdx: true)
        XCTAssertTrue(mdx.string.contains("2 imports, 1 export"))
        XCTAssertFalse(mdx.string.contains("./a"))
        // R01: alert tint differs per kind.
        XCTAssertNotEqual(NSColor(theme.alertTint(.note)), NSColor(theme.alertTint(.caution)))
    }

    func testCancelledBuildDoesNotReturnPartialDocument() async {
        let source = String(repeating: "# Heading\nParagraph with **bold**.\n\n", count: 1000)
        let blocks = MarkdownParser.parse(source)
        let task = Task.detached { try NativeMarkdownDocument.buildCancellable(source: source, blocks: blocks, theme: Theme(colorScheme: .light, scale: 1), documentURL: nil) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled build returned")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

extension NativeMarkdownDocumentTests {
    func testCrossBlockSelectionSurvivesInsertedParagraph() {
        let theme = Theme(colorScheme: .light, scale: 1)
        let before = "Alpha first\n\nBeta second\n\nGamma third\n"
        let after = "Inserted\n\n" + before
        let old = NativeMarkdownDocument.build(source: before, blocks: MarkdownParser.parse(before), theme: theme, documentURL: nil)
        let new = NativeMarkdownDocument.build(source: after, blocks: MarkdownParser.parse(after), theme: theme, documentURL: nil)
        let oldText = old.attributedString.string as NSString
        let start = oldText.range(of: "first").location
        let end = NSMaxRange(oldText.range(of: "second"))
        let selected = NSRange(location: start, length: end - start)
        guard let remapped = new.remappedSelection(selected, from: old) else { return XCTFail("selection lost") }
        XCTAssertEqual((new.attributedString.string as NSString).substring(with: remapped), oldText.substring(with: selected))
        XCTAssertGreaterThan(remapped.location, selected.location)
    }
}

extension NativeMarkdownDocumentTests {
    @MainActor func testHostedReloadKeepsViewportAndCrossBlockSelection() throws {
        _ = NSApplication.shared
        let paragraphs = (0..<120).map { "Paragraph \($0) has selectable text and a [link](https://example.com/\($0))." }.joined(separator: "\n\n")
        let source = paragraphs + "\n"
        let theme = Theme(colorScheme: .light, scale: 1)
        let old = NativeMarkdownDocument.build(source: source, blocks: MarkdownParser.parse(source), theme: theme, documentURL: nil)
        let controller = NativeMarkdownReadingView.Controller()
        let hosting = NSHostingView(rootView: NativeMarkdownReadingView(document: old, theme: theme, controller: controller))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 460), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        guard let view = findTextView(in: hosting) else { return XCTFail("missing native text view") }
        let target = old.blockRanges[60].id
        controller.jump(toBlock: target)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let first = view.string as NSString
        let start = first.range(of: "Paragraph 60").location
        let end = NSMaxRange(first.range(of: "Paragraph 62"))
        view.setSelectedRange(NSRange(location: start, length: end - start))
        let beforeText = first.substring(with: view.selectedRange())
        let beforeVisible = visibleBlock(in: view, document: old)
        let beforePixel = visiblePixelOffset(in: view)

        let changedSource = "Inserted lead paragraph.\n\n" + source
        let changed = NativeMarkdownDocument.build(source: changedSource, blocks: MarkdownParser.parse(changedSource), theme: theme, documentURL: nil)
        hosting.rootView = NativeMarkdownReadingView(document: changed, theme: theme, controller: controller)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        XCTAssertTrue(findTextView(in: hosting) === view)
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), beforeText)
        XCTAssertEqual(visibleBlock(in: view, document: changed), beforeVisible)
        XCTAssertLessThan(abs(visiblePixelOffset(in: view) - beforePixel), 12)
    }

    @MainActor func testHostedDocumentScrollsToItsLastLine() throws {
        _ = NSApplication.shared
        let source = (0..<80).map { "Paragraph \($0)." }.joined(separator: "\n\n") + "\n\n## Last heading\n"
        let theme = Theme(colorScheme: .light, scale: 1)
        let document = NativeMarkdownDocument.build(source: source, blocks: MarkdownParser.parse(source), theme: theme, documentURL: nil)
        let hosting = NSHostingView(rootView: NativeMarkdownReadingView(document: document, theme: theme, controller: .init()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 460), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        guard let view = findTextView(in: hosting), let layout = view.layoutManager, let container = view.textContainer else {
            return XCTFail("missing native text view")
        }
        view.scrollToEndOfDocument(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let textBottom = layout.usedRect(for: container).maxY + view.textContainerInset.height
        XCTAssertGreaterThanOrEqual(view.frame.height, textBottom + view.textContainerInset.height - 1)
        XCTAssertGreaterThanOrEqual(view.visibleRect.maxY, textBottom)
    }

    @MainActor private func findTextView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { self.findTextView(in: $0) }.first
    }

    @MainActor private func visibleBlock(in view: NSTextView, document: NativeMarkdownDocument) -> String? {
        let point = NSPoint(x: view.textContainerInset.width, y: view.visibleRect.minY + view.textContainerInset.height)
        let index = view.characterIndexForInsertion(at: point)
        return document.blockRanges.last(where: { $0.range.location <= index })?.id
    }

    @MainActor private func visiblePixelOffset(in view: NSTextView) -> CGFloat {
        guard let layout = view.layoutManager, let container = view.textContainer else { return 0 }
        let point = NSPoint(x: view.textContainerInset.width, y: view.visibleRect.minY + view.textContainerInset.height)
        let index = view.characterIndexForInsertion(at: point)
        let glyph = layout.glyphRange(forCharacterRange: NSRange(location: index, length: index < view.string.utf16.count ? 1 : 0), actualCharacterRange: nil)
        return view.visibleRect.minY - layout.boundingRect(forGlyphRange: glyph, in: container).minY
    }
}

extension NativeMarkdownDocumentTests {
    @MainActor func testHostedTaskMetadataAndCodeActions() throws {
        _ = NSApplication.shared
        let source = "---\ntitle: Example\n---\n- [ ] Todo\n\n```swift\nlet answer = 42\n```\n\n| Name | Value |\n| --- | --- |\n| Needle | 12 |\n"
        let theme = Theme(colorScheme: .light, scale: 1)
        let document = NativeMarkdownDocument.build(source: source, blocks: MarkdownParser.parse(source), theme: theme, documentURL: nil, expanded: [])
        let controller = NativeMarkdownReadingView.Controller()
        let pendingFindPasteboard = NSPasteboard(name: .find)
        pendingFindPasteboard.clearContents()
        pendingFindPasteboard.setString("Needle", forType: .string)
        controller.findNext()
        var toggled: (Int, Int, Bool)?
        var metadataClicks = 0
        var copyClicks = 0
        let reading = NativeMarkdownReadingView(document: document, theme: theme, controller: controller,
            onCheckbox: { toggled = ($0, $1, $2) }, onToggle: { _ in metadataClicks += 1 }, onCodeCopied: { copyClicks += 1 })
        let hosting = NSHostingView(rootView: reading)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        guard let view = findTextView(in: hosting) else { return XCTFail("missing native view") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "Needle")
        let marker = document.checkboxes[0].range.location
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: marker, in: view, window: window))
        XCTAssertEqual(toggled?.0, 0)
        XCTAssertEqual(toggled?.1, 0)
        XCTAssertEqual(toggled?.2, true)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: 0, in: view, window: window))
        XCTAssertEqual(metadataClicks, 1)
        let code = document.codeRanges[0]
        XCTAssertFalse(document.attributedString.string.contains("Copy  "))
        XCTAssertNil(document.attributedString.attribute(.link, at: code.range.location, effectiveRange: nil))
        let menu = view.menu(for: mouseEvent(.rightMouseDown, at: code.range.location, in: view, window: window))
        guard let item = menu?.items.first(where: { $0.title == "Copy Code" }), let action = item.action else { return XCTFail("missing code menu") }
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), code.code)
        XCTAssertEqual(copyClicks, 0, "code cards confirm in place, not with the window toast")
        guard let storage = view.textStorage, let layout = view.layoutManager,
              let card = (storage.attribute(.paragraphStyle, at: code.range.location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.first as? TypesetTextBlock
        else { return XCTFail("missing code card") }
        XCTAssertEqual(card.copyState, .copied)
        // Clicking the drawn Copy label copies the block.
        NSPasteboard.general.clearContents()
        let glyphs = layout.glyphRange(forCharacterRange: storage.range(of: card, at: code.range.location), actualCharacterRange: nil)
        let frame = layout.boundsRect(for: card, glyphRange: glyphs).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        let label = card.copyHitRect(inFrame: frame)
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(NSPoint(x: label.midX, y: label.midY), to: nil), modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        view.mouseDown(with: click)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), code.code)
        XCTAssertEqual(copyClicks, 0)
        let findPasteboard = NSPasteboard(name: .find)
        findPasteboard.clearContents()
        findPasteboard.setString("Needle", forType: .string)
        controller.showFind()
        controller.findNext()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "Needle")
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        var tokenColors: Set<String> = []
        view.textStorage?.enumerateAttribute(.foregroundColor, in: code.range) { value, _, _ in
            if let color = value as? NSColor { tokenColors.insert(color.description) }
        }
        XCTAssertGreaterThan(tokenColors.count, 1)
    }

    /// R04: the summary row fills on hover, and a toggle turns the chevron in place before the static image returns.
    @MainActor func testDetailsRowHoverAndChevronTurn() throws {
        _ = NSApplication.shared
        let source = "<details>\n<summary>More</summary>\n\nHidden body\n\n</details>\n\nAfter"
        let theme = Theme(colorScheme: .light, scale: 1)
        func build(_ expanded: Set<String>) -> NativeMarkdownDocument {
            NativeMarkdownDocument.build(source: source, blocks: MarkdownParser.parse(source), theme: theme, documentURL: nil, expanded: expanded)
        }
        var expanded: Set<String> = []
        var hosting: NSHostingView<NativeMarkdownReadingView>!
        func view(_ document: NativeMarkdownDocument) -> NativeMarkdownReadingView {
            NativeMarkdownReadingView(document: document, theme: theme, controller: NativeMarkdownReadingView.Controller(),
                onToggle: { key in
                    expanded.formSymmetricDifference([key])
                    hosting.rootView = view(build(expanded))
                }, onCodeCopied: {})
        }
        hosting = NSHostingView(rootView: view(build(expanded)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        guard let text = findTextView(in: hosting), let storage = text.textStorage, let layout = text.layoutManager as? ChipLayoutManager
        else { return XCTFail("missing native view") }
        let label = (storage.string as NSString).range(of: "More").location
        text.mouseMoved(with: mouseEvent(.mouseMoved, at: label, in: text, window: window))
        XCTAssertEqual(layout.hoveredRow?.location, 0)
        text.mouseDown(with: mouseEvent(.leftMouseDown, at: label, in: text, window: window))
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertTrue(storage.string.contains("Hidden body"))
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertTrue((storage.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)?.attachmentCell is ChevronCell)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNotNil((storage.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)?.image, "static chevron restored")
    }

    @MainActor private func mouseEvent(_ type: NSEvent.EventType, at index: Int, in view: NSTextView, window: NSWindow) -> NSEvent {
        view.scrollRangeToVisible(NSRange(location: index, length: 1))
        let glyph = view.layoutManager!.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        let rect = view.layoutManager!.boundingRect(forGlyphRange: glyph, in: view.textContainer!)
        let point = NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y)
        return NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}

extension NativeMarkdownDocumentTests {
    func testLargeTableBatchesRetainEveryCellAndAlignment() {
        let rows = (0..<450).map { "| Item\($0) | \($0) |" }.joined(separator: "\n")
        let source = "| Name | Value |\n| :--- | ---: |\n" + rows + "\n"
        let rendered = NativeMarkdownDocument.build(source: source, blocks: MarkdownParser.parse(source), theme: Theme(colorScheme: .light, scale: 1), documentURL: nil)
        let text = rendered.attributedString.string as NSString
        var tables: [NSTextTable] = []
        for row in [0, 198, 199, 200, 449] {
            let label = "Item\(row)"
            let index = text.range(of: label).location
            XCTAssertNotEqual(index, NSNotFound)
            guard let style = rendered.attributedString.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle,
                  let block = style.textBlocks.first as? NSTextTableBlock else { return XCTFail("missing cell \(row)") }
            XCTAssertEqual(block.startingRow, (row + 1) % 200)
            XCTAssertEqual(block.startingColumn, 0)
            tables.append(block.table)
            let valueIndex = text.range(of: "\n\(row)\n", options: [], range: NSRange(location: index, length: min(100, text.length - index))).location
            XCTAssertNotEqual(valueIndex, NSNotFound)
        }
        XCTAssertTrue(tables[0] === tables[1])
        XCTAssertFalse(tables[1] === tables[2])
        XCTAssertTrue(tables[2] === tables[3])
        XCTAssertFalse(tables[3] === tables[4])
        XCTAssertEqual(rendered.attributedString.string.components(separatedBy: "Item").count - 1, 450)
        let storage = NSTextStorage(attributedString: rendered.attributedString)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        let xPositions = [0, 198, 199, 200, 449].map { row -> CGFloat in
            let index = text.range(of: "Item\(row)").location
            let glyph = layout.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
            return layout.boundingRect(forGlyphRange: glyph, in: container).minX
        }
        for x in xPositions { XCTAssertLessThan(abs(x - xPositions[0]), 2) }
    }
}

extension NativeMarkdownDocumentTests {
    @MainActor func testHugeTableRasterWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["TYPESET_NATIVE_BIG_TABLE_BENCH"] == "1" else { throw XCTSkip("one-shot table raster benchmark") }
        _ = NSApplication.shared
        let rows = (0..<12000).map { "| Item \($0) with repeated cell text to stress native table layout | Value \($0) long enough to create wrapping |" }.joined(separator: "\n")
        let source = "| Name | Value |\n| :--- | ---: |\n" + rows + "\n"
        let parsedAt = CFAbsoluteTimeGetCurrent()
        let blocks = MarkdownParser.parse(source)
        let builtAt = CFAbsoluteTimeGetCurrent()
        let theme = Theme(colorScheme: .light, scale: 1)
        let document = NativeMarkdownDocument.build(source: source, blocks: blocks, theme: theme, documentURL: nil)
        let readyAt = CFAbsoluteTimeGetCurrent()
        let hosting = NSHostingView(rootView: NativeMarkdownReadingView(document: document, theme: theme, controller: .init()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        guard let view = findTextView(in: hosting) else { return XCTFail("missing native view") }
        let hostedAt = CFAbsoluteTimeGetCurrent()
        let glyph = view.layoutManager!.glyphRange(forCharacterRange: NSRange(location: 0, length: 1000), actualCharacterRange: nil)
        _ = view.layoutManager!.boundingRect(forGlyphRange: glyph, in: view.textContainer!)
        let layoutAt = CFAbsoluteTimeGetCurrent()
        let viewport = NSRect(origin: view.visibleRect.origin, size: NSSize(width: 820, height: 600))
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: viewport) { view.cacheDisplay(in: viewport, to: bitmap) }
        let rasterAt = CFAbsoluteTimeGetCurrent()
        print("NATIVE_SINGLE_TABLE_BENCH bytes=\(source.utf8.count) parse_ms=\(Int((builtAt-parsedAt)*1000)) build_ms=\(Int((readyAt-builtAt)*1000)) host_ms=\(Int((hostedAt-readyAt)*1000)) visible_layout_ms=\(Int((layoutAt-hostedAt)*1000)) raster_ms=\(Int((rasterAt-layoutAt)*1000))")
    }
}

extension NativeMarkdownDocumentTests {
    @MainActor func testHostedSnapshotsWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["TYPESET_NATIVE_SNAP"] == "1" else { throw XCTSkip("one-shot visual probe") }
        _ = NSApplication.shared
        let source = """
        ---
        title: Native reader
        status: Ready
        ---
        # Native reader
        A paragraph with **bold**, *italic*, ~~strike~~, [a link](https://example.com), and `inline code`.

        > A quotation with a quiet rule and readable wrapped text.

        - [ ] First task
          - [x] Nested completed task
        - A regular list item

        | Name | Status | Count |
        | :--- | :---: | ---: |
        | Alpha | **Ready** | 12 |
        | Beta | `code` | 42 |

        ```swift
        // A comment with readable contrast
        let answer = 42
        ```
        """
        for (name, scheme, appearance) in [
            ("light", ColorScheme.light, NSAppearance.Name.aqua),
            ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua)
        ] {
            let theme = Theme(colorScheme: scheme, scale: 1)
            let document = NativeMarkdownDocument.build(source: source, blocks: MarkdownParser.parse(source), theme: theme, documentURL: nil)
            let hosting = NSHostingView(rootView: NativeMarkdownReadingView(document: document, theme: theme, controller: .init()))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = hosting
            window.makeKeyAndOrderFront(nil)
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.10))
            guard let view = findTextView(in: hosting) else { return XCTFail("missing native view") }
            let rect = view.visibleRect
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: rect),
                  let output = URL(string: "file:///tmp/typeset-native-hosted-\(name).png") else { return XCTFail("no screenshot") }
            view.cacheDisplay(in: rect, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output)
            window.close()
        }
    }
}

extension NativeMarkdownDocumentTests {
    @MainActor func testHostedImageCopyHasAltAndRTFDPayload() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("pic.png"))
        let source = "Before ![Picture alt](pic.png) after"
        let theme = Theme(colorScheme: .light, scale: 1)
        let document = NativeMarkdownDocument.build(source: source, blocks: MarkdownParser.parse(source), theme: theme, documentURL: directory.appendingPathComponent("readme.md"))
        let controller = NativeMarkdownReadingView.Controller()
        let hosting = NSHostingView(rootView: NativeMarkdownReadingView(document: document, theme: theme, controller: controller))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 250), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        guard let view = findTextView(in: hosting) else { return XCTFail("missing native view") }
        let index = document.images[0].range.location
        for _ in 0..<20 {
            if (view.textStorage?.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment)?.fileWrapper != nil { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
        view.setSelectedRange(document.images[0].range)
        controller.copy()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Picture alt")
        guard let rtfd = NSPasteboard.general.data(forType: .rtfd) else { return XCTFail("missing image RTFD payload") }
        let restored = try NSAttributedString(data: rtfd, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
        XCTAssertNotNil((restored.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)?.fileWrapper)
    }
}

extension NativeMarkdownDocumentTests {
    func testCodeAndQuoteBlocksSurviveIntoLayout() {
        let source = "Body\n\n```swift\nlet a = 1\nlet b = 2\n```\n\n> Quote\n"
        let doc = NativeMarkdownDocument.build(source: source, blocks: MarkdownParser.parse(source), theme: Theme(colorScheme: .light, scale: 1), documentURL: nil)
        let text = doc.attributedString
        let codeAt = (text.string as NSString).range(of: "let a").location
        let quoteAt = (text.string as NSString).range(of: "Quote").location
        let codeStyle = text.attribute(.paragraphStyle, at: codeAt, effectiveRange: nil) as? NSParagraphStyle
        let quoteStyle = text.attribute(.paragraphStyle, at: quoteAt, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertTrue(codeStyle?.textBlocks.first is TypesetTextBlock, "code: \(String(describing: codeStyle?.textBlocks))")
        XCTAssertTrue(quoteStyle?.textBlocks.first is TypesetTextBlock, "quote: \(String(describing: quoteStyle?.textBlocks))")

        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 680, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let x = { (i: Int) in layout.lineFragmentUsedRect(forGlyphAt: layout.glyphIndexForCharacter(at: i), effectiveRange: nil).minX }
        XCTAssertEqual(x(codeAt) - x(0), 16, accuracy: 0.5)
        XCTAssertEqual(x(codeAt + 10) - x(0), 16, accuracy: 0.5, "every code line sits inside the card")
        XCTAssertEqual(x(quoteAt) - x(0), 17, accuracy: 0.5)
    }
}

extension NativeMarkdownDocumentTests {
    private func render(_ source: String) -> NativeMarkdownDocument {
        NativeMarkdownDocument.build(source: source, blocks: MarkdownParser.parse(source), theme: Theme(colorScheme: .light, scale: 1),
                                     documentURL: URL(fileURLWithPath: "/tmp/docs/readme.md"))
    }

    func testManyOrdinaryParagraphsRenderWithoutFootnotes() {
        let source = (0..<2_000).map { "Ordinary paragraph \($0) with no footnote.\n" }.joined(separator: "\n")
        let start = CFAbsoluteTimeGetCurrent()
        let document = render(source)
        print("NATIVE_PARAGRAPHS_BENCH count=2000 build_ms=\(Int((CFAbsoluteTimeGetCurrent() - start) * 1000))")
        XCTAssertEqual(document.blockRanges.count, 2_000)
        XCTAssertTrue(document.attributedString.string.contains("Ordinary paragraph 1999"))
        XCTAssertTrue(document.footnoteBlockIDs.isEmpty)
    }

    func testGitHubAlertsTitleTintAndUndimmedBody() {
        let doc = render("> [!warning]\n> Mind the *gap*.\n\n> Plain quote\n\n> [!NOTE] not alone\n> stays a quote\n")
        let text = doc.attributedString, plain = text.string as NSString
        XCTAssertFalse(text.string.lowercased().contains("[!warning]"))
        XCTAssertTrue(text.string.contains("[!NOTE] not alone"), "marker must be alone on its line")
        XCTAssertEqual(text.attribute(.foregroundColor, at: plain.range(of: "Warning").location, effectiveRange: nil) as? NSColor, NSColor(Theme(colorScheme: .light, scale: 1).alertTint(.warning)))
        XCTAssertNotNil(text.attribute(.attachment, at: plain.range(of: "Warning").location - 2, effectiveRange: nil))
        XCTAssertEqual(text.attribute(.foregroundColor, at: plain.range(of: "Mind").location, effectiveRange: nil) as? NSColor, .labelColor)
        XCTAssertEqual(text.attribute(.foregroundColor, at: plain.range(of: "Plain").location, effectiveRange: nil) as? NSColor, .secondaryLabelColor)
        let style = text.attribute(.paragraphStyle, at: plain.range(of: "Mind").location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertTrue(style?.textBlocks.first is TypesetTextBlock)
    }

    func testFootnotesNumberByReferenceAndMapToDefinitionBlock() {
        let source = "Second[^b] first[^a] again[^b] missing[^x] and [ref][id].\n\n[^a]: Alpha note\n    continued.\n[^b]: Beta note\n\n[id]: https://example.com\n"
        let blocks = MarkdownParser.parse(source)
        let doc = render(source)
        let plain = doc.attributedString.string
        XCTAssertTrue(plain.hasPrefix("Second1 first2 again1 missing[^x] and ref."), plain)
        XCTAssertTrue(plain.contains("2.\tAlpha note continued.\n1.\tBeta note"), plain)
        let ref = doc.attributedString.attribute(.link, at: ("Second" as NSString).length, effectiveRange: nil) as? URL
        XCTAssertEqual(ref?.fragment, "fn-b")
        let refLink = doc.attributedString.attribute(.link, at: (plain as NSString).range(of: "ref.").location, effectiveRange: nil) as? URL
        XCTAssertEqual(refLink?.host, "example.com")
        let definitionBlock = blocks.first { $0.startLine == 2 }?.id
        XCTAssertNotNil(definitionBlock)
        XCTAssertEqual(doc.footnoteBlockIDs, ["fn-a": definitionBlock!, "fn-b": definitionBlock!])
    }

    func testEntityEncodedFootnoteSyntaxStillResolves() {
        let document = render("Ref&#91;^a].\n\n&#91;^a]: Encoded note\n")
        let plain = document.attributedString.string
        XCTAssertTrue(plain.hasPrefix("Ref1."), plain)
        XCTAssertTrue(plain.contains("1.\tEncoded note"), plain)
        XCTAssertEqual(document.footnoteBlockIDs.count, 1)
    }

    func testEscapedFootnoteSyntaxStillResolves() {
        let document = render("Ref\\[\\^a].\n\n\\[\\^a]: Escaped note\n")
        let plain = document.attributedString.string
        XCTAssertTrue(plain.hasPrefix("Ref1."), plain)
        XCTAssertTrue(plain.contains("1.\tEscaped note"), plain)
        XCTAssertEqual(document.footnoteBlockIDs.count, 1)
    }

    func testBareURLFootnoteDefinitionKeepsLinkAndNumber() {
        let source = "Ref[^a].\n\n[^a]: https://example.com\n"
        let document = render(source)
        let plain = document.attributedString.string as NSString
        XCTAssertEqual(plain.range(of: "Ref1.").location, 0)
        XCTAssertNotEqual(plain.range(of: "1.\thttps://example.com").location, NSNotFound)
        guard plain.range(of: "https://example.com").location != NSNotFound else { return }
        let link = document.attributedString.attribute(.link,
            at: plain.range(of: "https://example.com").location, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.host, "example.com")
        XCTAssertEqual(document.footnoteBlockIDs.count, 1)
    }

    func testRelativeAndAngleURLFootnotesRemainVisible() {
        let source = "Local[^a] remote[^b].\n\n[^a]: notes.md\n[^b]: <https://example.com>\n"
        let document = render(source)
        let plain = document.attributedString.string
        XCTAssertTrue(plain.contains("1.\tnotes.md"), plain)
        XCTAssertTrue(plain.contains("2.\thttps://example.com"), plain)
        XCTAssertEqual(document.footnoteBlockIDs.count, 2)
    }

    func testMultilineInlineCodeKeepsFootnoteShapedLiteral() {
        let source = "`before\n[^a]: https://example.com\nafter`\n"
        let document = render(source)
        XCTAssertTrue(document.attributedString.string.contains("[^a]: https://example.com"))
        XCTAssertFalse(document.attributedString.string.contains("[^a]\\:"))
    }

    func testInlineBreakHasNoParagraphGap() {
        let document = render("First<br>Second\n")
        let text = document.attributedString
        XCTAssertEqual(text.string, "First\nSecond\n")
        let first = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let second = text.attribute(.paragraphStyle, at: 6, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(first?.paragraphSpacing, 0)
        XCTAssertGreaterThan(second?.paragraphSpacing ?? 0, 0)
    }

    func testReadmeHTMLRendersCommonTags() {
        let source = """
        <details>
        <summary>More &amp; less</summary>

        Hidden **content**.

        </details>

        <p align="center"><img src="logo.png" alt="Logo" width="100"></p>

        Press <kbd>K</kbd>, H<sub>2</sub>O, x<sup>2</sup>, <b>bold</b> <a href="https://x.com">site</a><br>next <span>raw</span>
        """
        let doc = render(source)
        let text = doc.attributedString, plain = text.string as NSString
        XCTAssertTrue(text.string.hasPrefix("\u{FFFC} More & less\nHidden content.\n\u{FFFC}\nPress K, H2O, x2, bold site\nnext <span>raw</span>"), text.string)
        XCTAssertEqual((text.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold), true)
        XCTAssertEqual(doc.images.first?.url?.path, "/tmp/docs/logo.png")
        XCTAssertEqual(doc.images.first?.alt, "Logo")
        XCTAssertEqual((text.attribute(.paragraphStyle, at: doc.images[0].range.location, effectiveRange: nil) as? NSParagraphStyle)?.alignment, .center)
        XCTAssertNotNil(text.attribute(.backgroundColor, at: plain.range(of: "K,").location, effectiveRange: nil))
        XCTAssertGreaterThan(text.attribute(.baselineOffset, at: plain.range(of: "x2").location + 1, effectiveRange: nil) as? CGFloat ?? 0, 0)
        XCTAssertLessThan(text.attribute(.baselineOffset, at: plain.range(of: "H2").location + 1, effectiveRange: nil) as? CGFloat ?? 0, 0)
        XCTAssertEqual((text.attribute(.font, at: plain.range(of: "bold").location, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold), true)
        XCTAssertEqual((text.attribute(.link, at: plain.range(of: "site").location, effectiveRange: nil) as? URL)?.host, "x.com")
    }

    func testHTMLCommentsRenderNothingButKeepBlocks() {
        let source = "<!-- human note\nacross lines -->\n\nBody <!-- inline --> text\n\n<!-- tail -->\n"
        let blocks = MarkdownParser.parse(source)
        let doc = render(source)
        XCTAssertEqual(doc.attributedString.string, "Body  text\n")
        XCTAssertEqual(doc.blockRanges.map(\.id), blocks.map(\.id))
        XCTAssertEqual(doc.block(at: 0)?.id, blocks[1].id)
        let edited = render(source.replacingOccurrences(of: "Body", with: "Bodies"))
        XCTAssertEqual(edited.replacementRanges(from: doc).old, NSRange(location: 0, length: 11))
    }

    @MainActor func testBareURLsWWWAndEmailsBecomeLinks() {
        let doc = render("See https://example.com/a. Or (www.example.org), mail dee@example.com, `https://code.example` too.\n")
        let text = doc.attributedString, plain = text.string as NSString
        func link(_ needle: String) -> URL? { text.attribute(.link, at: plain.range(of: needle).location, effectiveRange: nil) as? URL }
        XCTAssertEqual(link("https://example.com")?.absoluteString, "https://example.com/a")
        XCTAssertNil(text.attribute(.link, at: plain.range(of: "/a.").location + 2, effectiveRange: nil), "trailing period stays text")
        XCTAssertEqual(link("www.")?.absoluteString, "https://www.example.org")
        XCTAssertNil(text.attribute(.link, at: plain.range(of: "),").location, effectiveRange: nil))
        XCTAssertEqual(link("dee@")?.absoluteString, "mailto:dee@example.com")
        XCTAssertNil(link("code.example"), "code spans stay literal")
        for url in [link("https://example.com")!, link("www.")!, link("dee@")!] {
            var opened = false
            _ = NativeMarkdownReadingView.Coordinator.handleLink(url, onLink: nil) { _ in opened = true; return true }
            XCTAssertTrue(opened, url.absoluteString)
        }
    }

    func testBadgeRowsArePillsButALoneWebImageKeepsItsCard() {
        let doc = render("""
        [![CI](https://ci.example/badge.svg)](https://ci.example) [![npm](https://npm.example/v.svg)](https://npm.example)

        Text ![](https://shields.example/x.svg)

        <p><a href="https://site.example"><img src="https://img.example/b.svg" alt="B"></a></p>

        ![Hero](https://cdn.example/hero.png)
        """)
        let text = doc.attributedString, plain = text.string as NSString
        XCTAssertEqual(doc.images.map(\.alt), ["Hero"])
        XCTAssertEqual((text.attribute(.link, at: plain.range(of: "CI").location, effectiveRange: nil) as? URL)?.host, "ci.example")
        XCTAssertNotNil(text.attribute(.backgroundColor, at: plain.range(of: "npm").location, effectiveRange: nil))
        XCTAssertEqual((text.attribute(.link, at: plain.range(of: "shields.example").location, effectiveRange: nil) as? URL)?.host, "shields.example")
        XCTAssertEqual((text.attribute(.link, at: plain.range(of: "B\n").location, effectiveRange: nil) as? URL)?.host, "site.example")
    }

    func testSoftBreakAfterBRDoesNotIndentNextLine() {
        XCTAssertEqual(render("foo<br>\nbar\n").attributedString.string, "foo\nbar\n")
    }

    func testSummaryChevronKeepsImageRangesOnTheImage() {
        let doc = render("<details>\n<summary><img src=\"a.png\"> Title</summary>\n\nBody\n\n</details>\n")
        let text = doc.attributedString
        XCTAssertEqual(doc.images.count, 1)
        let location = doc.images[0].range.location
        XCTAssertGreaterThan(location, 0, "slot 0 is the chevron")
        XCTAssertNil(text.attribute(.typesetChevronOpen, at: location, effectiveRange: nil))
        XCTAssertNotNil(text.attribute(.typesetChevronOpen, at: 0, effectiveRange: nil))
    }

    func testH6ContrastAndExpandedMetadataHasNoMoreCount() {
        let doc = render("###### Small\n")
        XCTAssertEqual(doc.attributedString.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .secondaryLabelColor)
        let source = "---\ndate: 2024-01-02\nlayout: post\nslug: a\n---\nBody\n"
        let theme = Theme(colorScheme: .light, scale: 1)
        let open = NativeMarkdownDocument.build(source: source, blocks: MarkdownParser.parse(source), theme: theme, documentURL: nil, expanded: ["metadata"])
        let closed = NativeMarkdownDocument.build(source: source, blocks: MarkdownParser.parse(source), theme: theme, documentURL: nil, expanded: [])
        XCTAssertFalse(open.attributedString.string.contains("more"), open.attributedString.string)
        XCTAssertTrue(closed.attributedString.string.contains("2 more"), closed.attributedString.string)
    }

    func testSingleParseDocumentRendersLikeTheParsingBuild() {
        let theme = Theme(colorScheme: .light, scale: 1)
        let cases: [(String, URL?)] = [
            ("---\ntitle: T\n---\n# H\n\nText[^1] with **bold** and [ref].\n\n[^1]: Note\n\n[ref]: https://example.com\n", nil),
            ("---\ntitle: T\n---\nimport { Callout } from './c'\n\n<Callout>\n[ref] inside **bold**\n</Callout>\n\n[ref]: https://example.com\n", URL(fileURLWithPath: "/tmp/post.mdx"))
        ]
        for (source, url) in cases {
            let mdx = MarkdownParser.isMDX(url)
            let parsed = MarkdownParser.parseDocument(source, mdx: mdx)
            let reused = NativeMarkdownDocument.build(source: source, blocks: parsed.blocks, document: parsed.document, theme: theme, documentURL: url)
            let fresh = NativeMarkdownDocument.build(source: source, blocks: MarkdownParser.parse(source, mdx: mdx), theme: theme, documentURL: url)
            XCTAssertEqual(reused.attributedString.string, fresh.attributedString.string) // attachments are distinct instances, so compare text
            XCTAssertEqual(reused.blockRanges.map(\.id), fresh.blockRanges.map(\.id))
            let linkRange = (reused.attributedString.string as NSString).range(of: "ref")
            XCTAssertNotEqual(linkRange.location, NSNotFound)
            XCTAssertEqual((reused.attributedString.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL)?.absoluteString,
                           "https://example.com", "mdx=\(mdx): \(reused.attributedString.string)")
            XCTAssertEqual(reused.attributedString.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL,
                           fresh.attributedString.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL)
        }
    }

    @MainActor func testInlineAndDisplayMathDelimiters() {
        typealias P = NativeMarkdownMath.Piece
        XCTAssertEqual(NativeMarkdownMath.split("area $\\pi r^2$ here"), [P.text("area "), .math("\\pi r^2"), .text(" here")])
        XCTAssertEqual(NativeMarkdownMath.split("costs $5 and $10 today"), [P.text("costs $5 and $10 today")])
        XCTAssertEqual(NativeMarkdownMath.split("escaped \\$5 and $x$"), [P.text("escaped \\$5 and "), .math("x")])
        XCTAssertEqual(NativeMarkdownMath.split("$ x$ and $x $"), [P.text("$ x$ and $x $")])
        XCTAssertEqual(NativeMarkdownMath.split("$x$1 then $y$."), [P.text("$x$1 then "), .math("y"), .text(".")])
        XCTAssertEqual(NativeMarkdownMath.split("$$"), [P.text("$$")])
        XCTAssertEqual(NativeMarkdownMath.displayTeX("$$\n\\int_0^1 x\\,dx\n$$"), "\\int_0^1 x\\,dx")
        XCTAssertNil(NativeMarkdownMath.displayTeX("$$a$$ and $$b$$"))

        let source = "Inline $a^2$ and $`b_1`$ end.\n\n$$\nx \\\\ y\n$$\n"
        let doc = render(source)
        XCTAssertEqual(doc.diagrams.map(\.source), ["a^2", "b_1", "x \\\\ y"])
        XCTAssertEqual(doc.diagrams.map(\.kind), [.inlineMath, .inlineMath, .displayMath])
        XCTAssertTrue(doc.attributedString.string.hasPrefix("Inline \u{FFFC} and \u{FFFC} end."))
        let materialized = doc.materializedAttributedString()
        XCTAssertTrue((materialized.attribute(.attachment, at: doc.diagrams[0].range.location, effectiveRange: nil) as? NSTextAttachment)?.attachmentCell is DiagramCell)
    }

    @MainActor func testMermaidFenceRecordsPlaceholderAndSplicesOnEdit() {
        let source = "# Flow\n\n```mermaid\ngraph TD\n  A --> B\n```\n\nAfter\n"
        let doc = render(source)
        XCTAssertEqual(doc.diagrams.count, 1)
        let diagram = doc.diagrams[0]
        XCTAssertEqual(diagram.kind, .mermaid)
        XCTAssertEqual(diagram.source, "graph TD\n  A --> B")
        XCTAssertEqual((doc.attributedString.string as NSString).substring(with: diagram.range), "\u{FFFC}")
        let materialized = doc.materializedAttributedString()
        XCTAssertTrue((materialized.attribute(.attachment, at: diagram.range.location, effectiveRange: nil) as? NSTextAttachment)?.attachmentCell is DiagramCell)
        XCTAssertTrue(doc.codeRanges.isEmpty)

        let edited = source.replacingOccurrences(of: "B", with: "C")
        let next = render(edited)
        XCTAssertGreaterThan(next.replacementRanges(from: doc).new.length, 0)
    }

    @MainActor func testOfflineDiagramAndMathRenderer() async {
        let renderer = DiagramRenderer.shared
        let flow = "graph LR\n  A[Start] --> B{Ok?}\n  B -->|yes| C[Done]"
        guard case .image(let image, let png, _) = await renderer.render(flow, kind: .mermaid, isDark: false, fontSize: 16) else {
            return XCTFail("flowchart failed")
        }
        XCTAssertGreaterThan(image.size.width, 50)
        XCTAssertNotNil(png)

        guard case .image = await renderer.render("sequenceDiagram\n  Alice->>Bob: Hi\n  Bob-->>Alice: Yo", kind: .mermaid, isDark: true, fontSize: 16) else {
            return XCTFail("sequence diagram failed")
        }

        guard case .failure(let brokenMsg) = await renderer.render("flowchart TD\n  A -->", kind: .mermaid, isDark: false, fontSize: 16) else {
            return XCTFail("broken diagram rendered unexpectedly")
        }
        XCTAssertFalse(brokenMsg.isEmpty)

        guard case .failure(let unsupportedMsg) = await renderer.render("gantt\n  title A", kind: .mermaid, isDark: false, fontSize: 16) else {
            return XCTFail("unsupported diagram rendered unexpectedly")
        }
        XCTAssertFalse(unsupportedMsg.isEmpty)

        guard case .image(let math, let mathPng, let descent) = await renderer.render("x^2 + \\frac{1}{y}", kind: .inlineMath, isDark: false, fontSize: 16) else {
            return XCTFail("math failed")
        }
        XCTAssertGreaterThan(descent, 0)
        XCTAssertLessThan(math.size.height, 60)
        XCTAssertNotNil(mathPng)

        guard case .failure = await renderer.render("\\frac{", kind: .displayMath, isDark: false, fontSize: 16) else {
            return XCTFail("broken TeX rendered unexpectedly")
        }
    }
}
