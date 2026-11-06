import AppKit
import Darwin
import MarcoCore
import PDFKit
import SwiftUI
import XCTest
@testable import Marco

@MainActor
final class DocumentLifecycleTests: XCTestCase {
    func testHelpResourcesAreBundled() throws {
        for name in ["Welcome", "Privacy", "ThirdPartyNotices"] {
            XCTAssertNotNil(Bundle.main.url(forResource: name, withExtension: "md"), "missing \(name).md")
        }
        let notices = try String(contentsOf: XCTUnwrap(Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "md")), encoding: .utf8)
        XCTAssertTrue(notices.contains("Swift cmark 0.8.0 — COPYING"))
        XCTAssertTrue(notices.contains("Highlightr 2.3.0 — LICENSE"))
    }

    private func file(_ text: String = "# Original\n") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("marco-lifecycle-\(UUID().uuidString).md")
        try Data(text.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func loaded(_ url: URL) async -> DocumentReloadController {
        let controller = DocumentReloadController(url: url)
        controller.start()
        while controller.isLoading { try? await Task.sleep(for: .milliseconds(10)) }
        return controller
    }

    func testViewerSaveCannotOverwriteFile() async throws {
        let url = try file()
        let controller = await loaded(url)
        XCTAssertFalse(controller.save())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Original\n")
        controller.stop()
    }

    func testWriteImmediatelyAfterStartIsLoaded() async throws {
        let url = try file()
        let controller = DocumentReloadController(url: url)
        controller.start()
        try Data("# Changed before watcher readiness\n".utf8).write(to: url, options: .atomic)
        while controller.isLoading { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.currentText, "# Changed before watcher readiness\n")
        controller.stop()
    }

    func testConflictBlocksSaveExitAndCloseUntilChosen() async throws {
        let url = try file()
        let controller = await loaded(url)
        _ = controller.enterEditMode()
        controller.noteEditedTextChanged("# Local\n")
        try Data("# External\n".utf8).write(to: url, options: .atomic)
        XCTAssertFalse(controller.save())
        XCTAssertEqual(controller.conflictState, .conflictPending)
        XCTAssertFalse(controller.exitEditMode(caretLine: nil).allowed)
        XCTAssertFalse(controller.prepareToLeave())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# External\n")
        controller.resolveConflictKeepMine()
        XCTAssertTrue(controller.save())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Local\n")
        controller.stop()
    }

    func testFailedSaveRetainsBufferAndBlocksClose() async throws {
        let url = try file()
        let controller = await loaded(url)
        _ = controller.enterEditMode()
        controller.noteEditedTextChanged("# Local\n")
        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(controller.prepareToLeave())
        XCTAssertTrue(controller.isEditing)
        XCTAssertEqual(controller.editedText, "# Local\n")
        XCTAssertNotNil(controller.saveError)
        controller.stop()
    }

    func testStaleCheckboxDoesNotReplaceExternalText() async throws {
        let url = try file("- [ ] Task\n")
        let controller = await loaded(url)
        try Data("- [ ] Task\nExternal\n".utf8).write(to: url, options: .atomic)
        controller.toggleCheckbox(blockStartLine: 0, itemLineOffset: 0, checked: true)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "- [ ] Task\nExternal\n")
        controller.stop()
    }

    func testUTF8BOMSurvivesSaveAndCheckbox() async throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let url = try file()
        try (bom + Data("- [ ] Task\n".utf8)).write(to: url)
        let controller = await loaded(url)
        XCTAssertEqual(controller.currentText, "- [ ] Task\n")
        controller.toggleCheckbox(blockStartLine: 0, itemLineOffset: 0, checked: true)
        XCTAssertEqual(try Data(contentsOf: url), bom + Data("- [x] Task\n".utf8))
        _ = controller.enterEditMode()
        controller.noteEditedTextChanged("- [x] Task\nMore\n")
        XCTAssertTrue(controller.save())
        XCTAssertEqual(try Data(contentsOf: url), bom + Data("- [x] Task\nMore\n".utf8))
        controller.stop()
    }

    func testCanonicallyEquivalentExternalBytesConflict() async throws {
        let url = try file("# Caf\u{00E9}\n")
        let controller = await loaded(url)
        _ = controller.enterEditMode()
        controller.noteEditedTextChanged("# Local\n")
        try Data("# Cafe\u{0301}\n".utf8).write(to: url, options: .atomic)
        XCTAssertFalse(controller.save())
        XCTAssertEqual(controller.conflictState, .conflictPending)
        XCTAssertEqual(try Data(contentsOf: url), Data("# Cafe\u{0301}\n".utf8))
        controller.stop()
    }

    func testNormalizationOnlyReloadThenCheckboxKeepsExternalBytes() async throws {
        let url = try file("- [ ] Caf\u{00E9}\n")
        let controller = await loaded(url)
        let reloaded = expectation(description: "normalization change reloaded")
        controller.onReloadApplied = { _ in reloaded.fulfill() }
        try Data("- [ ] Cafe\u{0301}\n".utf8).write(to: url, options: .atomic)
        await fulfillment(of: [reloaded], timeout: 3)
        controller.toggleCheckbox(blockStartLine: 0, itemLineOffset: 0, checked: true)
        XCTAssertEqual(try Data(contentsOf: url), Data("- [x] Cafe\u{0301}\n".utf8))
        controller.onReloadApplied = nil
        controller.stop()
    }

    func testNormalizationOnlyEditIsDirtyAndSavesBytes() async throws {
        let url = try file("# Caf\u{00E9}\n")
        let controller = await loaded(url)
        _ = controller.enterEditMode()
        controller.noteEditedTextChanged("# Cafe\u{0301}\n")
        XCTAssertEqual(controller.conflictState, .dirty)
        XCTAssertTrue(controller.save())
        XCTAssertEqual(try Data(contentsOf: url), Data("# Cafe\u{0301}\n".utf8))
        controller.stop()
    }

    func testSymlinkSavePreservesLinkTargetPermissionsAndXattr() async throws {
        let target = try file()
        let link = target.deletingLastPathComponent().appendingPathComponent("marco-link-\(UUID().uuidString).md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
        let value = Array("keep".utf8)
        XCTAssertEqual(target.path.withCString { path in
            value.withUnsafeBytes { setxattr(path, "com.dee.marco.test", $0.baseAddress, value.count, 0, 0) }
        }, 0)
        let controller = await loaded(link)
        _ = controller.enterEditMode()
        controller.noteEditedTextChanged("# Saved\n")
        XCTAssertTrue(controller.save())
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "# Saved\n")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int, 0o640)
        var readback = [UInt8](repeating: 0, count: 16)
        let capacity = readback.count
        let count = target.path.withCString { path in
            readback.withUnsafeMutableBytes { getxattr(path, "com.dee.marco.test", $0.baseAddress, capacity, 0, 0) }
        }
        XCTAssertEqual(Array(readback.prefix(max(count, 0))), value)
        controller.stop()
    }

    func testRetargetedSymlinkCannotOverwriteNewTarget() async throws {
        let original = try file()
        let other = try file("# Other\n")
        let link = original.deletingLastPathComponent().appendingPathComponent("marco-link-\(UUID().uuidString).md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        defer { try? FileManager.default.removeItem(at: link) }
        let controller = await loaded(link)
        _ = controller.enterEditMode()
        controller.noteEditedTextChanged("# Local\n")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        XCTAssertFalse(controller.save())
        XCTAssertEqual(controller.conflictState, .conflictPending)
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "# Other\n")
        controller.stop()
    }

    func testLateReloadDoesNotReplaceNewEdit() async throws {
        let url = try file()
        let controller = await loaded(url)
        _ = controller.enterEditMode()
        let ready = expectation(description: "reload computed")
        controller.onReloadReady = {
            controller.noteEditedTextChanged("# Typed while parsing\n")
            ready.fulfill()
        }
        try Data("# External\n".utf8).write(to: url, options: .atomic)
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertEqual(controller.editedText, "# Typed while parsing\n")
        XCTAssertEqual(controller.conflictState, .conflictPending)
        controller.onReloadReady = nil
        controller.stop()
    }

    func testNavigationRejectionKeepsHistory() async throws {
        let first = try file()
        let second = try file("# Second\n")
        let model = WindowModel()
        model.load(initial: first)
        while model.controller?.isLoading == true { try? await Task.sleep(for: .milliseconds(10)) }
        _ = model.controller?.enterEditMode()
        model.controller?.noteEditedTextChanged("# Local\n")
        try Data("# External\n".utf8).write(to: first, options: .atomic)
        model.navigate(to: second)
        XCTAssertEqual(model.currentURL, first.standardizedFileURL)
        XCTAssertEqual(model.history.count, 1)
        XCTAssertFalse(model.prepareToClose())
        model.stop()
    }

    func testHistoryBackAndForwardRejectUnresolvedConflict() async throws {
        let first = try file("# First\n")
        let second = try file("# Second\n")
        let third = try file("# Third\n")
        let model = WindowModel()
        model.load(initial: first)
        while model.controller?.isLoading == true { try? await Task.sleep(for: .milliseconds(10)) }
        model.navigate(to: second)
        while model.controller?.isLoading == true { try? await Task.sleep(for: .milliseconds(10)) }
        model.navigate(to: third)
        model.goBack()
        while model.controller?.isLoading == true { try? await Task.sleep(for: .milliseconds(10)) }
        _ = model.controller?.enterEditMode()
        model.controller?.noteEditedTextChanged("# Local\n")
        try Data("# External\n".utf8).write(to: second, options: .atomic)
        model.goBack()
        XCTAssertEqual(model.currentURL, second.standardizedFileURL)
        XCTAssertEqual(model.historyIndex, 1)
        model.goForward()
        XCTAssertEqual(model.currentURL, second.standardizedFileURL)
        XCTAssertEqual(model.historyIndex, 1)
        model.stop()
    }

    func testSaveAsAfterFailureRetargetsAndAllowsClose() async throws {
        let original = try file()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("marco-saved-copy-\(UUID().uuidString).md")
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }
        let model = WindowModel()
        model.load(initial: original)
        while model.controller?.isLoading == true { try? await Task.sleep(for: .milliseconds(10)) }
        _ = model.controller?.enterEditMode()
        model.controller?.noteEditedTextChanged("# Saved copy\n")
        try FileManager.default.removeItem(at: original)
        XCTAssertFalse(model.prepareToClose())
        XCTAssertFalse(model.saveAs(to: original))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(model.saveAs(to: destination))
        XCTAssertEqual(model.currentURL, destination.standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "# Saved copy\n")
        XCTAssertTrue(model.prepareToClose())
        model.stop()
    }

    func testSaveAsPreservesBOMAndRejectsAliasOfOriginal() async throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let original = try file()
        try (bom + Data("# Original\n".utf8)).write(to: original)
        let alias = original.deletingLastPathComponent().appendingPathComponent("marco-alias-\(UUID().uuidString).md")
        let destination = original.deletingLastPathComponent().appendingPathComponent("marco-copy-\(UUID().uuidString).md")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        defer {
            try? FileManager.default.removeItem(at: alias)
            try? FileManager.default.removeItem(at: destination)
        }
        let model = WindowModel()
        model.load(initial: original)
        while model.controller?.isLoading == true { try? await Task.sleep(for: .milliseconds(10)) }
        _ = model.controller?.enterEditMode()
        model.controller?.noteEditedTextChanged("# Copy\n")
        XCTAssertFalse(model.saveAs(to: alias))
        XCTAssertEqual(try Data(contentsOf: original), bom + Data("# Original\n".utf8))
        XCTAssertTrue(model.saveAs(to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), bom + Data("# Copy\n".utf8))
        model.stop()
    }

    func testTakeTheirsRestoresBufferWhenDiskReverts() async throws {
        let url = try file()
        let controller = await loaded(url)
        _ = controller.enterEditMode()
        controller.noteEditedTextChanged("# Local\n")
        try Data("# External\n".utf8).write(to: url, options: .atomic)
        XCTAssertFalse(controller.save())
        try Data("# Original\n".utf8).write(to: url, options: .atomic)
        let applied = expectation(description: "reload computed")
        controller.onReloadReady = { applied.fulfill() }
        controller.resolveConflictTakeTheirs()
        await fulfillment(of: [applied], timeout: 3)
        XCTAssertEqual(controller.editedText, "# Original\n")
        XCTAssertEqual(controller.conflictState, .clean)
        controller.onReloadReady = nil
        controller.stop()
    }

    func testReloadRetriesAfterEditAndUndo() async throws {
        let url = try file()
        let controller = await loaded(url)
        _ = controller.enterEditMode()
        let applied = expectation(description: "newer reload applied")
        var readyCount = 0
        controller.onReloadReady = {
            readyCount += 1
            if readyCount == 1 {
                controller.noteEditedTextChanged("# Temporary\n")
                controller.noteEditedTextChanged("# Original\n")
            }
        }
        controller.onReloadApplied = { _ in applied.fulfill() }
        try Data("# External\n".utf8).write(to: url, options: .atomic)
        await fulfillment(of: [applied], timeout: 3)
        XCTAssertGreaterThanOrEqual(readyCount, 2)
        XCTAssertEqual(controller.editedText, "# External\n")
        controller.onReloadReady = nil
        controller.onReloadApplied = nil
        controller.stop()
    }

    func testLoadFailureCannotOpenBlankEditor() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("marco-missing-\(UUID().uuidString).md")
        let controller = await loaded(url)
        XCTAssertNotNil(controller.loadError)
        _ = controller.enterEditMode()
        XCTAssertFalse(controller.isEditing)
        try Data("# Recovered\n".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let recovered = expectation(description: "recovered file loaded")
        controller.onInitialLoaded = { if controller.loadError == nil { recovered.fulfill() } }
        await fulfillment(of: [recovered], timeout: 3)
        XCTAssertFalse(controller.isEditing)
        XCTAssertEqual(controller.currentText, "# Recovered\n")
        controller.onInitialLoaded = nil
        controller.stop()
    }

    func testNativeCloseAndAppQuitRespectConflict() async throws {
        let url = try file()
        let model = WindowModel()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        model.window = window
        DocumentOpener.shared.register(model)
        defer {
            DocumentOpener.shared.unregister(model)
            model.stop()
            window.delegate = nil
        }
        model.load(initial: url)
        while model.controller?.isLoading == true { try? await Task.sleep(for: .milliseconds(10)) }
        _ = model.controller?.enterEditMode()
        model.controller?.noteEditedTextChanged("# Local\n")
        try Data("# External\n".utf8).write(to: url, options: .atomic)
        XCTAssertFalse(window.delegate?.windowShouldClose?(window) ?? true)
        XCTAssertEqual(AppDelegate().applicationShouldTerminate(NSApp), .terminateCancel)
        model.controller?.resolveConflictKeepMine()
        XCTAssertTrue(model.controller?.save() == true)
        XCTAssertTrue(window.delegate?.windowShouldClose?(window) ?? false)
        XCTAssertEqual(AppDelegate().applicationShouldTerminate(NSApp), .terminateNow)
    }

    func testWindowSnapshotKeepsTableAndReferenceLinkNavigation() async throws {
        let secondName = "marco-second-\(UUID().uuidString).md"
        let first = try file("# Page\n\n[Next][n]\n\n[n]: \(secondName)#part\n\n| A | B |\n|---|---|\n| one | two |\n")
        let second = first.deletingLastPathComponent().appendingPathComponent(secondName)
        try Data("# Part\n".utf8).write(to: second)
        defer { try? FileManager.default.removeItem(at: second) }
        let model = WindowModel()
        model.load(initial: first)
        for _ in 0..<300 where model.readingSnapshot == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard let snapshot = model.readingSnapshot else { XCTFail("snapshot did not build"); return }
        XCTAssertTrue(snapshot.attributedString.string.contains("one"))
        XCTAssertTrue(snapshot.attributedString.string.contains("two"))
        let next = (snapshot.attributedString.string as NSString).range(of: "Next")
        let link = snapshot.attributedString.attribute(.link, at: next.location, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.fragment, "part")
        XCTAssertTrue(model.openReadingLink(try XCTUnwrap(link)))
        XCTAssertEqual(model.currentURL, second.standardizedFileURL)
        XCTAssertEqual(model.history.count, 2)
        model.stop()
    }

    func testSourceEditorUsesNativeFindBar() {
        let handle = SourceEditorHandle()
        let color = NSColor.labelColor
        let colors = MarkdownSyntaxStyler.Colors(
            heading: color, link: color, code: color, codeBackground: color, dim: color)
        let hosting = NSHostingView(rootView: SourceEditorView(text: .constant("find me"), colors: colors, handle: handle))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        hosting.layoutSubtreeIfNeeded()
        func textView(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap(textView).first
        }
        XCTAssertTrue(textView(in: hosting)?.usesFindBar == true)
        handle.find(.showFindInterface)
    }

    func testCloseProxyPreservesExistingWindowDelegate() {
        final class DenyClose: NSObject, NSWindowDelegate {
            func windowShouldClose(_ sender: NSWindow) -> Bool { false }
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let original = DenyClose()
        window.delegate = original
        let model = WindowModel()
        model.window = window
        XCTAssertFalse(window.delegate?.windowShouldClose?(window) ?? true)
        window.delegate = original // SwiftUI may reinstall its delegate during an update.
        model.window = window
        XCTAssertFalse(window.delegate === original)
        XCTAssertFalse(window.delegate?.windowShouldClose?(window) ?? true)
        window.delegate = nil
    }

    func testRichCopyUsesLiveSourceWhileSnapshotRebuilds() async throws {
        let url = try file()
        let model = WindowModel()
        model.load(initial: url)
        for _ in 0..<300 where model.readingSnapshot == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        _ = model.controller?.enterEditMode()
        model.controller?.noteEditedTextChanged("# Latest source\n")
        XCTAssertTrue(model.controller?.save() == true)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("marco-copy-test-\(UUID().uuidString)"))
        model.copyAsRichText(pasteboard: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "# Latest source\n")
        for _ in 0..<300 where pasteboard.data(forType: .rtfd) == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "# Latest source\n")
        XCTAssertNotNil(pasteboard.data(forType: .rtfd))
        model.copyAsRichText(pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("Other app copy", forType: .string)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(pasteboard.string(forType: .string), "Other app copy")
        XCTAssertNil(pasteboard.data(forType: .rtfd))
        model.stop()
    }

    func testPDFPaginatesNativeTableAndLastParagraph() async throws {
        let source = "---\nsecret: omitted metadata\n---\n\n| A | B |\n|---|---|\n| Table first | Table second |\n\n"
            + (0..<400).map { "Paragraph \($0): long readable text across the page.\n\n" }.joined()
            + "FINAL PARAGRAPH MARKER\n"
        let attributed = await PDFExporter.preparedDocument(source: source, url: nil)
        XCTAssertFalse(attributed.string.contains("omitted metadata"))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("marco-pdf-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: destination) }
        XCTAssertTrue(PDFExporter.run(attributed: attributed, savingTo: destination))
        let pdf = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        let extracted = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined()
        XCTAssertTrue(extracted.contains("Table first"))
        XCTAssertTrue(extracted.contains("FINAL PARAGRAPH MARKER"))
    }
}
