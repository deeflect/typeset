import AppKit
import Highlightr
import SwiftUI

/// Syntax highlighting for fenced code blocks via Highlightr (highlight.js
/// in JavaScriptCore). Runs off the main thread on a serial queue (one
/// `Highlightr` instance per appearance, since it isn't thread-safe) and
/// caches results by (code, language, appearance).
///
/// The returned `AttributedString` carries only per-token foreground
/// colors — no baked font — so the code-block view applies the themed
/// SF Mono at render time and text-size scaling works without
/// re-highlighting.
/// `@unchecked Sendable`: engines stay on the serial queue; the cache has
/// its own short lock so view-body lookups never wait for JavaScriptCore.
public final class CodeHighlighter: @unchecked Sendable {
    public static let shared = CodeHighlighter()

    private struct Key: Hashable {
        let code: String
        let language: String
        let isDark: Bool
    }

    private let queue = DispatchQueue(label: "com.dee.marco.highlight", qos: .userInitiated)
    private var lightEngine: Highlightr?
    private var darkEngine: Highlightr?
    private var cache: [Key: AttributedString] = [:]
    private var nativeCache: [Key: NSAttributedString] = [:]
    private let cacheLock = NSLock()
    private let cacheLimit = 2000

    private init() {}

    /// Highlights `code`, or returns `nil` when there's no usable language
    /// tag or highlighting fails — the caller then renders plain monospace.
    public func highlighted(code: String, language: String?, isDark: Bool) async -> AttributedString? {
        guard let language, !language.isEmpty else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                let key = Key(code: code, language: language.lowercased(), isDark: isDark)
                self.cacheLock.lock()
                let hit = self.cache[key]
                self.cacheLock.unlock()
                if let hit {
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
                self.cacheLock.lock()
                if self.cache.count > self.cacheLimit { self.cache.removeAll(keepingCapacity: true) }
                self.cache[key] = attributed
                self.cacheLock.unlock()
                continuation.resume(returning: attributed)
            }
        }
    }

    /// Native token colors for TextKit and rich export; keeps the caller's font.
    public func highlightedNative(code: String, language: String?, isDark: Bool) async -> NSAttributedString? {
        guard let language, !language.isEmpty else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                let key = Key(code: code, language: language.lowercased(), isDark: isDark)
                self.cacheLock.lock()
                let hit = self.nativeCache[key]
                self.cacheLock.unlock()
                if let hit { continuation.resume(returning: hit); return }
                guard let engine = self.engine(isDark: isDark),
                      let raw = engine.highlight(code, as: language.lowercased(), fastRender: true)
                        ?? engine.highlight(code, as: nil, fastRender: true) else {
                    continuation.resume(returning: nil)
                    return
                }
                let result = NSMutableAttributedString(attributedString: raw)
                result.removeAttribute(.font, range: NSRange(location: 0, length: result.length))
                if isDark {
                    var fixes: [(NSRange, NSColor)] = []
                    result.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: result.length)) { value, range, _ in
                        if let color = value as? NSColor { fixes.append((range, Self.readableDarkColor(color))) }
                    }
                    for (range, color) in fixes { result.addAttribute(.foregroundColor, value: color, range: range) }
                }
                let immutable = result.copy() as! NSAttributedString
                self.cacheLock.lock()
                if self.nativeCache.count > self.cacheLimit { self.nativeCache.removeAll(keepingCapacity: true) }
                self.nativeCache[key] = immutable
                self.cacheLock.unlock()
                continuation.resume(returning: immutable)
            }
        }
    }

    /// Synchronous cache read — lets a view show highlighted code on its
    /// first frame when the result is already cached (and powers snapshot
    /// rendering, which can't await).
    public func cached(code: String, language: String?, isDark: Bool) -> AttributedString? {
        guard let language, !language.isEmpty else { return nil }
        let key = Key(code: code, language: language.lowercased(), isDark: isDark)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }

    /// Synchronously compute and cache (used to pre-warm before a snapshot).
    @discardableResult
    public func warm(code: String, language: String?, isDark: Bool) -> AttributedString? {
        guard let language, !language.isEmpty else { return nil }
        return queue.sync {
            let key = Key(code: code, language: language.lowercased(), isDark: isDark)
            cacheLock.lock()
            let hit = cache[key]
            cacheLock.unlock()
            if let hit { return hit }
            guard let engine = engine(isDark: isDark),
                  let highlighted = engine.highlight(code, as: language.lowercased(), fastRender: true)
            else { return nil }
            let attributed = Self.stripFont(highlighted)
            cacheLock.lock()
            if cache.count > cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[key] = attributed
            cacheLock.unlock()
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

    private static func readableDarkColor(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return color }
        func luminance(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGFloat {
            func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
        let background = luminance(0.13, 0.13, 0.145)
        var red = rgb.redComponent, green = rgb.greenComponent, blue = rgb.blueComponent
        while (luminance(red, green, blue) + 0.05) / (background + 0.05) < 4.5 {
            red += (1 - red) * 0.1
            green += (1 - green) * 0.1
            blue += (1 - blue) * 0.1
        }
        return NSColor(deviceRed: red, green: green, blue: blue, alpha: rgb.alphaComponent)
    }
}
