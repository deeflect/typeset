import Foundation
import XCTest
@testable import TypesetRendering

final class CodeHighlighterTests: XCTestCase {
    func testUnknownLanguageSkipsAutoDetection() async {
        let code = (0..<500).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let highlighter = CodeHighlighter.shared
        let start = CFAbsoluteTimeGetCurrent()
        let native = await highlighter.highlightedNative(code: code, language: "not-a-language", isDark: false)
        XCTAssertNil(native)
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, 1)
    }

    func testCanonicalAndAliasesPreserveCodeAndReuseCache() async {
        let code = (0..<500).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let highlighter = CodeHighlighter.shared
        for language in ["swift", "js", "ts", "py", "sh"] {
            let native = await highlighter.highlightedNative(code: code, language: language, isDark: false)
            XCTAssertEqual(native?.string, code, language)
        }
        let first = await highlighter.highlightedNative(code: code, language: "SWIFT", isDark: true)
        let second = await highlighter.highlightedNative(code: code, language: "swift", isDark: true)
        XCTAssertEqual(first?.string, code)
        XCTAssertTrue(first === second)
    }

    func testOversizedCodeUsesPlainFallback() async {
        let code = String(repeating: "x", count: 65_537)
        let native = await CodeHighlighter.shared.highlightedNative(code: code, language: "swift", isDark: false)
        XCTAssertNil(native)
    }
}
