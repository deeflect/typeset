import AppKit
import XCTest

@MainActor
final class PreviewViewControllerTests: XCTestCase {
    func testCappedSourceStopsAtLastLineBreak() {
        XCTAssertEqual(PreviewViewController.capped("short", limit: 10), "short")
        let capped = PreviewViewController.capped("line one\nline two\n", limit: 12)
        XCTAssertTrue(capped.hasPrefix("line one\n\n---"))
        XCTAssertTrue(capped.contains("first 2 MB"))
    }

    func testFailedPrepareClearsPreviousPreview() async throws {
        let first = FileManager.default.temporaryDirectory.appendingPathComponent("typeset-ql-\(UUID().uuidString).md")
        let invalid = FileManager.default.temporaryDirectory.appendingPathComponent("typeset-ql-\(UUID().uuidString).md")
        try Data("# First\n".utf8).write(to: first)
        try Data([0xFF]).write(to: invalid)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: invalid) }
        let preview = PreviewViewController()
        _ = preview.view
        let firstError = await withCheckedContinuation { continuation in
            preview.preparePreviewOfFile(at: first) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(firstError)
        XCTAssertEqual(preview.view.subviews.count, 1)
        let invalidError = await withCheckedContinuation { continuation in
            preview.preparePreviewOfFile(at: invalid) { continuation.resume(returning: $0) }
        }
        XCTAssertNotNil(invalidError)
        XCTAssertTrue(preview.view.subviews.isEmpty)
        XCTAssertNil(preview.installedColorScheme)
    }

    func testRepeatedPrepareReplacesHostedReader() async throws {
        let first = FileManager.default.temporaryDirectory.appendingPathComponent("typeset-ql-\(UUID().uuidString).md")
        let second = FileManager.default.temporaryDirectory.appendingPathComponent("typeset-ql-\(UUID().uuidString).md")
        try Data("# First\n".utf8).write(to: first)
        try Data("# Second\n".utf8).write(to: second)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let preview = PreviewViewController()
        _ = preview.view
        let firstError = await withCheckedContinuation { continuation in
            preview.preparePreviewOfFile(at: first) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(firstError)
        XCTAssertEqual(preview.view.subviews.count, 1)
        let secondError = await withCheckedContinuation { continuation in
            preview.preparePreviewOfFile(at: second) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(secondError)
        XCTAssertEqual(preview.view.subviews.count, 1)
        let prior = preview.view.subviews[0]
        let installsBeforeAppearance = preview.installationCount
        let dark = preview.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        preview.view.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
        for _ in 0..<300 where preview.installationCount == installsBeforeAppearance {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(preview.view.subviews.count, 1)
        XCTAssertFalse(preview.view.subviews.first === prior)

        let installsBeforeOverlap = preview.installationCount
        let pending = expectation(description: "Finder prepare completes despite appearance change")
        var pendingError: Error?
        preview.preparePreviewOfFile(at: first) { error in
            pendingError = error
            pending.fulfill()
        }
        preview.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        await fulfillment(of: [pending], timeout: 3)
        XCTAssertNil(pendingError)
        for _ in 0..<300 where preview.installationCount < installsBeforeOverlap + 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(preview.installationCount, installsBeforeOverlap + 2)
        XCTAssertEqual(preview.installedColorScheme, dark ? .dark : .light)
    }
}
