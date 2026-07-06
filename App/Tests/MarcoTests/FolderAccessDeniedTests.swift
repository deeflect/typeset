import MarcoRendering
import XCTest
@testable import Marco

/// `FolderAccessStore.isAccessDenied` distinguishes "sandbox denied this
/// read" from "the file just isn't there" by inspecting `errno` after a raw
/// `open()` — sandbox violations surface as `EPERM`/`EACCES`, a missing
/// file as `ENOENT`. There's no sandbox active in the unit-test process, so
/// this exercises the same errno branch using a POSIX permission-denied
/// file as a stand-in for a sandbox denial, which is the practical way to
/// unit test this without an actual sandboxed process.
final class FolderAccessDeniedTests: XCTestCase {
    func testMissingFileIsNotReportedAsAccessDenied() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("marco-does-not-exist-\(UUID().uuidString).md")
        XCTAssertFalse(FolderAccessStore.isAccessDenied(at: missing))
    }

    func testPermissionDeniedFileIsReportedAsAccessDenied() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marco-access-denied-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let file = dir.appendingPathComponent("locked.md")
        try Data("locked".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)

        // Root (and some CI sandboxes) can bypass POSIX permission bits —
        // skip rather than false-fail in that environment.
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: file.path), "current user can bypass POSIX permissions")

        XCTAssertTrue(FolderAccessStore.isAccessDenied(at: file))
    }

    func testReadableFileIsNotReportedAsAccessDenied() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("marco-readable-\(UUID().uuidString).md")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertFalse(FolderAccessStore.isAccessDenied(at: file))
    }
}
