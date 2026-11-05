import AppKit
import MarcoCore
import SwiftUI
import XCTest
@testable import MarcoRendering

final class NativeMarkdownDocumentTests: XCTestCase {
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

    func testLocalImageExportKeepsOffsets() async throws {
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
        let narrow = NativeMarkdownImages.attachment(for: await NativeMarkdownImages.load(directory.appendingPathComponent("pic.png")), maxWidth: 1)
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
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/marco-native-renderer-probe.png"))
        }
    }
}

extension NativeMarkdownDocumentTests {
    @MainActor func testBenchmarkWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["MARCO_NATIVE_BENCH"] == "1" else { throw XCTSkip("one-shot benchmark") }
        let section = "# Heading\nParagraph with **bold**, [link](https://example.com), and `code`.\n\n| Left | Right |\n| :--- | ---: |\n| A | 42 |\n\n"
        let prose = "# Heading\nParagraph with **bold**, *italic*, and [link](https://example.com). This is normal wrapped prose in a reading document.\n\n"
        for (kind, source) in [
            ("tables-small", String(repeating: section, count: 100)),
            ("tables-large", String(repeating: section, count: 10000)),
            ("prose-50k", String(repeating: prose, count: 500)),
            ("prose-1m", String(repeating: prose, count: 10000))
        ] {
            let start = CFAbsoluteTimeGetCurrent()
            let blocks = MarkdownParser.parse(source)
            let parsed = CFAbsoluteTimeGetCurrent()
            let theme = Theme(colorScheme: .light, scale: 1)
            let first = NativeMarkdownDocument.build(source: source, blocks: blocks, theme: theme, documentURL: nil)
            let built = CFAbsoluteTimeGetCurrent()
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
            let changed = NativeMarkdownDocument.build(source: updated, blocks: MarkdownParser.parse(updated), theme: theme, documentURL: nil)
            let rebuilt = CFAbsoluteTimeGetCurrent()
            let splice = changed.replacementRanges(from: first)
            storage.replaceCharacters(in: splice.old, with: changed.attributedString.attributedSubstring(from: splice.new))
            let reinstalled = CFAbsoluteTimeGetCurrent()
            print("NATIVE_BENCH kind=\(kind) bytes=\(source.utf8.count) parse_ms=\(Int((parsed-start)*1000)) build_ms=\(Int((built-parsed)*1000)) install_ms=\(Int((installed-built)*1000)) visible_ms=\(Int((visible-installed)*1000)) reload_build_ms=\(Int((rebuilt-visible)*1000)) reload_install_ms=\(Int((reinstalled-rebuilt)*1000))")
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
        XCTAssertTrue(open.attributedString.string.contains("title: Sample"))
        XCTAssertFalse(closed.attributedString.string.contains("title: Sample"))
        XCTAssertFalse(open.attributedString.string.contains("---"))
        XCTAssertTrue(closed.attributedString.string.contains("Heading"))
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
        let document = NativeMarkdownDocument.build(source: source, blocks: MarkdownParser.parse(source), theme: theme, documentURL: nil)
        let controller = NativeMarkdownReadingView.Controller()
        let pendingFindPasteboard = NSPasteboard(name: .find)
        pendingFindPasteboard.clearContents()
        pendingFindPasteboard.setString("Needle", forType: .string)
        controller.findNext()
        var toggled: (Int, Int, Bool)?
        var metadataClicks = 0
        var copyClicks = 0
        let reading = NativeMarkdownReadingView(document: document, theme: theme, controller: controller,
            onCheckbox: { toggled = ($0, $1, $2) }, onMetadataToggle: { metadataClicks += 1 }, onCodeCopied: { copyClicks += 1 })
        let hosting = NSHostingView(rootView: reading)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
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
        XCTAssertEqual(copyClicks, 1)
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
        guard ProcessInfo.processInfo.environment["MARCO_NATIVE_BIG_TABLE_BENCH"] == "1" else { throw XCTSkip("one-shot table raster benchmark") }
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
        guard ProcessInfo.processInfo.environment["MARCO_NATIVE_SNAP"] == "1" else { throw XCTSkip("one-shot visual probe") }
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
            window.appearance = NSAppearance(named: appearance)
            window.contentView = hosting
            window.makeKeyAndOrderFront(nil)
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.10))
            guard let view = findTextView(in: hosting) else { return XCTFail("missing native view") }
            let rect = view.visibleRect
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: rect),
                  let output = URL(string: "file:///tmp/marco-native-hosted-\(name).png") else { return XCTFail("no screenshot") }
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
