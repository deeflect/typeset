import XCTest
@testable import Typeset

/// Folder mode's pure pieces: the recursive scan and Open Quickly ranking.
final class FolderIndexTests: XCTestCase {
    private func entry(_ path: String) -> FolderIndex.Entry {
        FolderIndex.Entry(url: URL(fileURLWithPath: "/r/" + path), relativePath: path, modified: .distantPast)
    }

    func testScanIncludesDotFoldersExcludesBuildTreesAndCaps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ["README.md", ".claude/plans/next.md", "specs/a.markdown", "notes.txt",
                     ".git/HEAD.md", "node_modules/x/README.md", "dist/out.md", "a/b/c/d/e/f/g/h/i/deep.md",
                     ".venv/lib/x.md", "target/doc.md", "build/out.md", "__pycache__/x.md", ".next/x.md"]
        for path in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("# x".utf8).write(to: url)
        }
        let found = Set(FolderIndex.scan(root).map(\.relativePath))
        XCTAssertEqual(found, ["README.md", ".claude/plans/next.md", "specs/a.markdown"])
        XCTAssertEqual(FolderIndex.scan(root, limit: 2).count, 2)
        XCTAssertLessThan(FolderIndex.scan(root, maxVisited: 1).count, 3)
        XCTAssertEqual(FolderIndex.entryFile(in: FolderIndex.scan(root))?.relativePath, "README.md")
    }

    func testRankPutsFilenameMatchesFirstAndKeepsRecencyOnTies() {
        // Input order = most recent first.
        let files = [entry("plans/claude-notes.md"), entry("x/plan.md"), entry("CLAUDE.md"), entry("other.md")]
        XCTAssertEqual(FolderIndex.rank("", in: files).map(\.relativePath), files.map(\.relativePath))
        // Both are filename-prefix matches: recency decides.
        XCTAssertEqual(FolderIndex.rank("claude", in: files).map(\.relativePath), ["plans/claude-notes.md", "CLAUDE.md"])
        // Filename substring beats filename subsequence.
        XCTAssertEqual(FolderIndex.rank("note", in: files).map(\.relativePath), ["plans/claude-notes.md"])
        // "pln": filename subsequence (plan.md) beats a path-only match (plans/…).
        XCTAssertEqual(FolderIndex.rank("pln", in: files).map(\.relativePath), ["x/plan.md", "plans/claude-notes.md"])
        XCTAssertTrue(FolderIndex.rank("zzz", in: files).isEmpty)
    }

    func testMatchedOffsetsPrefersSubstringThenSubsequence() {
        XCTAssertEqual(FolderIndex.matchedOffsets("not", in: "claude-notes.md"), [7, 8, 9])
        XCTAssertEqual(FolderIndex.matchedOffsets("pln", in: "plan.md"), [0, 1, 3])
        XCTAssertEqual(FolderIndex.matchedOffsets("zz", in: "plan.md"), [])
        XCTAssertEqual(FolderIndex.matchedOffsets("", in: "plan.md"), [])
    }
}
