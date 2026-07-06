import AppKit
import Highlightr
import SwiftUI

/// Syntax highlighting for fenced code blocks via Highlightr (highlight.js
/// in JavaScriptCore). Runs off the main thread on a serial queue (one
/// `Highlightr` instance per appearance, since it isn't thread-safe) and
/// caches results by (code hash, language, appearance).
///
/// The returned `AttributedString` carries only per-token foreground
/// colors — no baked font — so the code-block view applies the themed
/// SF Mono at render time and text-size scaling works without
/// re-highlighting.
/// `@unchecked Sendable`: all mutable state (`cache`, the engines) is only
/// ever touched inside `queue`, so it's safe to share across tasks.
final class CodeHighlighter: @unchecked Sendable {
    static let shared = CodeHighlighter()

    private struct Key: Hashable {
        let codeHash: Int
        let language: String
        let isDark: Bool
    }

    private let queue = DispatchQueue(label: "com.dee.marco.highlight", qos: .userInitiated)
    private var lightEngine: Highlightr?
    private var darkEngine: Highlightr?
    private var cache: [Key: AttributedString] = [:]
    private let cacheLimit = 2000

    private init() {}

    /// Highlights `code`, or returns `nil` when there's no usable language
    /// tag or highlighting fails — the caller then renders plain monospace.
    func highlighted(code: String, language: String?, isDark: Bool) async -> AttributedString? {
        guard let language, !language.isEmpty else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                let key = Key(codeHash: code.hashValue, language: language.lowercased(), isDark: isDark)
                if let hit = self.cache[key] {
                    continuation.resume(returning: hit)
                    return
                }

                let engine = self.engine(isDark: isDark)
                guard let engine,
                      let highlighted = engine.highlight(code, as: language.lowercased(), fastRender: true)
                        ?? engine.highlight(code, as: nil, fastRender: true)
                else {
                    continuation.resume(returning: nil)
                    return
                }

                let attributed = Self.stripFont(highlighted)
                if self.cache.count > self.cacheLimit { self.cache.removeAll(keepingCapacity: true) }
                self.cache[key] = attributed
                continuation.resume(returning: attributed)
            }
        }
    }

    /// Synchronous cache read — lets a view show highlighted code on its
    /// first frame when the result is already cached (and powers snapshot
    /// rendering, which can't await).
    func cached(code: String, language: String?, isDark: Bool) -> AttributedString? {
        guard let language, !language.isEmpty else { return nil }
        let key = Key(codeHash: code.hashValue, language: language.lowercased(), isDark: isDark)
        return queue.sync { cache[key] }
    }

    /// Synchronously compute and cache (used to pre-warm before a snapshot).
    @discardableResult
    func warm(code: String, language: String?, isDark: Bool) -> AttributedString? {
        guard let language, !language.isEmpty else { return nil }
        return queue.sync {
            let key = Key(codeHash: code.hashValue, language: language.lowercased(), isDark: isDark)
            if let hit = cache[key] { return hit }
            guard let engine = engine(isDark: isDark),
                  let highlighted = engine.highlight(code, as: language.lowercased(), fastRender: true)
            else { return nil }
            let attributed = Self.stripFont(highlighted)
            cache[key] = attributed
            return attributed
        }
    }

    private func engine(isDark: Bool) -> Highlightr? {
        if isDark {
            if darkEngine == nil {
                let engine = Highlightr()
                engine?.setTheme(to: "atom-one-dark")
                darkEngine = engine
            }
            return darkEngine
        } else {
            if lightEngine == nil {
                let engine = Highlightr()
                engine?.setTheme(to: "xcode")
                lightEngine = engine
            }
            return lightEngine
        }
    }

    /// Rebuilds the string keeping only foreground colors, dropping the
    /// baked font so the view controls size/scaling.
    private static func stripFont(_ ns: NSAttributedString) -> AttributedString {
        var result = AttributedString()
        let full = NSRange(location: 0, length: ns.length)
        let nsString = ns.string as NSString
        ns.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            var piece = AttributedString(nsString.substring(with: range))
            if let color = value as? NSColor {
                piece.foregroundColor = Color(nsColor: color)
            }
            result.append(piece)
        }
        return result
    }
}
