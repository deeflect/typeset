import AppKit
import XCTest

@MainActor
final class PreviewViewControllerTests: XCTestCase {
    private func read(_ data: Data, limit: Int) throws -> (text: String, bytesRead: Int) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("typeset-ql-\(UUID().uuidString).md")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try PreviewViewController.readCappedSource(url, limit: limit)
    }

    func testCappedSourceStopsAtLastLineBreak() {
        XCTAssertEqual(PreviewViewController.capped("short", limit: 10), "short")
        let capped = PreviewViewController.capped("line one\nline two\n", limit: 12)
        XCTAssertTrue(capped.hasPrefix("line one\n\n---"))
        XCTAssertTrue(capped.contains("first 2 MB"))
    }

    func testBoundedReadMatchesValidFullSourceIncludingBOMAndSplitScalar() throws {
        let cases: [(Data, Int)] = [
            (Data("short".utf8), 5),
            (Data("short!".utf8), 5),
            (Data([0xEF, 0xBB, 0xBF]), 1),
            (Data([0xEF, 0xBB, 0xBF]) + Data("short".utf8), 5),
            (Data("one\ntwo\nthree".utf8), 8),
            (Data([0xEF, 0xBB, 0xBF]) + Data("one\ntwo\nthree".utf8), 8)
        ]
        for (data, limit) in cases {
            let full = try XCTUnwrap(String(data: data, encoding: .utf8))
            let result = try read(data, limit: limit)
            XCTAssertEqual(result.text, PreviewViewController.capped(full, limit: limit))
            XCTAssertLessThanOrEqual(result.bytesRead, limit + 4)
        }
        for prefix in [Data(), Data([0xEF, 0xBB, 0xBF])] {
            for scalar in ["é", "€", "😀"] {
                let data = prefix + Data("ab\(scalar)tail".utf8)
                let full = try XCTUnwrap(String(data: data, encoding: .utf8))
                for limit in 1...full.utf8.count {
                    let result = try read(data, limit: limit)
                    XCTAssertEqual(result.text, PreviewViewController.capped(full, limit: limit), "limit=\(limit), scalar=\(scalar), BOM=\(!prefix.isEmpty)")
                    XCTAssertLessThanOrEqual(result.bytesRead, limit + 4)
                }
            }
        }
        let huge = Data("line\n".utf8) + Data(repeating: UInt8(ascii: "a"), count: 3 * 1024 * 1024)
        let result = try read(huge, limit: PreviewViewController.previewLimit)
        XCTAssertEqual(result.bytesRead, PreviewViewController.previewLimit + 4)
        XCTAssertEqual(result.text, PreviewViewController.capped(String(decoding: huge, as: UTF8.self)))
    }

    func testBoundedReadRejectsMalformedVisibleUTF8AndPropagatesFileErrors() throws {
        XCTAssertThrowsError(try read(Data([0x61, 0xFF, 0x0A, 0x62]), limit: 3))
        XCTAssertThrowsError(try read(Data([0xF0, 0x0A, 0x62, 0x63]), limit: 3))
        XCTAssertThrowsError(try read(Data([0x61, 0xE0, 0x80, 0x62]), limit: 3))
        XCTAssertThrowsError(try read(Data([0x61, 0xF0]), limit: 3))
        XCTAssertNoThrow(try read(Data([0x61, 0x0A, 0xFF, 0x62, 0x63]), limit: 3))
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("typeset-ql-missing-\(UUID().uuidString).md")
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("typeset-ql-link-\(UUID().uuidString).md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)
        defer { try? FileManager.default.removeItem(at: link) }
        XCTAssertThrowsError(try PreviewViewController.readCappedSource(missing))
        XCTAssertThrowsError(try PreviewViewController.readCappedSource(link))
    }

    func testBoundedReadFollowsValidSymlinkAndChecksCancellation() async throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("typeset-ql-\(UUID().uuidString).md")
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("typeset-ql-link-\(UUID().uuidString).md")
        try Data("# Linked\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: link); try? FileManager.default.removeItem(at: target) }
        XCTAssertEqual(try PreviewViewController.readCappedSource(link).text, "# Linked\n")
        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PreviewViewController.readCappedSource(target).text
        }
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled read succeeded")
        } catch is CancellationError {
        }
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
