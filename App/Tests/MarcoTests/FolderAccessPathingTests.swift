import XCTest
@testable import Marco

/// Covers the pure ancestor-walk logic `FolderAccessStore` relies on to
/// decide "is this file already covered by a granted folder" and "would
/// granting this folder duplicate an existing grant". Deliberately doesn't
/// touch bookmark/security-scope APIs (hard to unit test in-process) — see
/// PLAN §8.
final class FolderAccessPathingTests: XCTestCase {
    func testExactFolderMatchIsContained() {
        XCTAssertTrue(FolderAccessPathing.isPath("/Users/dee/Docs", containedIn: "/Users/dee/Docs"))
    }

    func testFileDirectlyInsideGrantedFolderIsContained() {
        XCTAssertTrue(FolderAccessPathing.isPath("/Users/dee/Docs/readme.md", containedIn: "/Users/dee/Docs"))
    }

    func testFileInNestedSubfolderIsContained() {
        XCTAssertTrue(FolderAccessPathing.isPath("/Users/dee/Docs/assets/img/pic.png", containedIn: "/Users/dee/Docs"))
    }

    func testSiblingFolderWithSharedPrefixIsNotContained() {
        // "/Users/dee/Docs2" must not be treated as inside "/Users/dee/Docs"
        // just because the string has the folder as a prefix.
        XCTAssertFalse(FolderAccessPathing.isPath("/Users/dee/Docs2/file.md", containedIn: "/Users/dee/Docs"))
    }

    func testUnrelatedPathIsNotContained() {
        XCTAssertFalse(FolderAccessPathing.isPath("/Users/dee/Other/file.md", containedIn: "/Users/dee/Docs"))
    }

    func testAncestorFolderIsNotContainedInDescendant() {
        // Walk direction only goes one way: a parent isn't "inside" its child.
        XCTAssertFalse(FolderAccessPathing.isPath("/Users/dee", containedIn: "/Users/dee/Docs"))
    }

    func testTrailingSlashesAreNormalized() {
        XCTAssertTrue(FolderAccessPathing.isPath("/Users/dee/Docs/file.md", containedIn: "/Users/dee/Docs/"))
        XCTAssertTrue(FolderAccessPathing.isPath("/Users/dee/Docs/", containedIn: "/Users/dee/Docs"))
    }

    func testEmptyGrantedFolderNeverContainsAnything() {
        XCTAssertFalse(FolderAccessPathing.isPath("/Users/dee/Docs/file.md", containedIn: ""))
    }

    // MARK: - coveringFolder (dedupe / "never ask twice")

    func testCoveringFolderFindsTheAncestorAmongSeveralGrants() {
        let granted = ["/Users/dee/Projects/A", "/Users/dee/Docs", "/Users/dee/Projects/B"]
        XCTAssertEqual(
            FolderAccessPathing.coveringFolder(for: "/Users/dee/Docs/notes/todo.md", among: granted),
            "/Users/dee/Docs")
    }

    func testCoveringFolderReturnsNilWhenNothingMatches() {
        let granted = ["/Users/dee/Projects/A", "/Users/dee/Docs"]
        XCTAssertNil(FolderAccessPathing.coveringFolder(for: "/Users/dee/Elsewhere/file.md", among: granted))
    }

    func testCoveringFolderTreatsAnAlreadyGrantedSubfolderAsCovered() {
        // If "/Users/dee/Docs" is granted, granting "/Users/dee/Docs/assets"
        // again would be redundant — the store uses this to skip re-prompting.
        let granted = ["/Users/dee/Docs"]
        XCTAssertNotNil(FolderAccessPathing.coveringFolder(for: "/Users/dee/Docs/assets", among: granted))
    }
}
