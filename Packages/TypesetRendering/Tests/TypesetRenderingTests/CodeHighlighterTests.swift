import Foundation
import XCTest
@testable import TypesetRendering

final class CodeHighlighterTests: XCTestCase {
    func testUnknownLanguageSkipsAutoDetectionOnEveryEntryPoint() async {
        let code = (0..<500).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let highlighter = CodeHighlighter.shared
        let start = CFAbsoluteTimeGetCurrent()
        let native = await highlighter.highlightedNative(code: code, language: "not-a-language", isDark: false)
        let attributed = await highlighter.highlighted(code: code, language: "not-a-language", isDark: false)
        let warm = highlighter.warm(code: code, language: "not-a-language", isDark: false)
        XCTAssertNil(native)
        XCTAssertNil(attributed)
        XCTAssertNil(warm)
        XCTAssertNil(highlighter.cached(code: code, language: "not-a-language", isDark: false))
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, 1)
    }

    func testCanonicalAndAliasesPreserveCode() async {
        let code = (0..<500).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let highlighter = CodeHighlighter.shared
        for language in ["swift", "js", "ts", "py", "sh"] {
            let native = await highlighter.highlightedNative(code: code, language: language, isDark: false)
            XCTAssertEqual(native?.string, code, language)
        }
        let highlighted = await highlighter.highlighted(code: code, language: "SWIFT", isDark: false)
        XCTAssertEqual(highlighted.map { String($0.characters) }, code)
        XCTAssertEqual(highlighter.warm(code: code, language: "swift", isDark: true).map { String($0.characters) }, code)
        XCTAssertEqual(highlighter.cached(code: code, language: "swift", isDark: true).map { String($0.characters) }, code)
    }

    func testOversizedCodeUsesPlainFallback() async {
        let code = String(repeating: "x", count: 65_537)
        let native = await CodeHighlighter.shared.highlightedNative(code: code, language: "swift", isDark: false)
        XCTAssertNil(native)
        XCTAssertNil(CodeHighlighter.shared.warm(code: code, language: "swift", isDark: false))
    }
}
