import AppKit
import Highlightr
import SwiftUI

/// Syntax highlighting for fenced code blocks via Highlightr (highlight.js
/// in JavaScriptCore). Runs off the main thread on a serial queue (one
/// `Highlightr` instance per appearance, since it isn't thread-safe) and
/// caches results by (code, language, appearance).
///
/// The returned `NSAttributedString` carries only per-token foreground
/// colors — no baked font — so the reader applies the themed SF Mono at
/// render time and text-size scaling works without re-highlighting.
/// `@unchecked Sendable`: engines stay on the serial queue; `nativeCache`
/// uses thread-safe `NSCache`.
public final class CodeHighlighter: @unchecked Sendable {
    public static let shared = CodeHighlighter()

    private final class Cached: NSObject, @unchecked Sendable {
        let attributed: NSAttributedString
        init(_ attributed: NSAttributedString) { self.attributed = attributed }
    }

    private let queue = DispatchQueue(label: "com.deeflect.typeset.highlight", qos: .userInitiated)
    private var lightEngine: Highlightr?
    private var darkEngine: Highlightr?
    nonisolated(unsafe) private let nativeCache: NSCache<NSString, Cached> = {
        let cache = NSCache<NSString, Cached>()
        cache.countLimit = 256
        return cache
    }()

    // Canonical names and aliases from Highlightr 2.3.0's bundled highlight.js 11.11.1.
    // Highlightr auto-detects on an unknown name, so reject it before creating an engine.
    private static let languages = Set("""
    1c abnf accesslog actionscript ada ado adoc ahk angelscript apache apacheconf applescript arcade arduino arm armasm
    as asc asciidoc aspectj atom autohotkey autoit avrasm awk axapta bash basic bat bf bind bnf
    brainfuck c c# c++ cal capnp capnproto cc ceylon cjs clean clj clojure clojure-repl cls cmake
    cmake.in cmd coffee coffeescript console coq cos cpp cr craftcms crm crmsh crystal cs csharp cson
    csp css cts cxx d dart dcl delphi dfm diff django dns do docker dockerfile dos
    dpr dsconfig dst dts dust ebnf edn elixir elm erb erl erlang erlang-repl ex excel exs
    f# f90 f95 feature fix flix fortran fs fsharp gams gauss gcode gemspec gherkin glsl gml
    gms go golang golo gql gradle graph graphql groovy gss gyp h h++ haml handlebars haskell
    haxe hbs hh hpp hs hsp html html.handlebars html.hbs htmlbars http https hx hxx hy hylang
    i7 iced icl inform7 ini ino instances ipython irb irpf90 isbl java javascript jboss-cli jinja jldoctest
    js json jsonc jsp jsx julia julia-repl k kdb kotlin kt kts lasso lassoscript latex ldif
    leaf less lisp livecodeserver livescript llvm ls lsl lua m mak make makefile markdown mathematica matlab
    maxima md mel mercury mikrotik mips mipsasm mizar mjs mk mkd mkdown ml mm mma mojolicious
    monkey moo moon moonscript mts n1ql nc nestedtext nginx nginxconf nim nix nixos node-repl nsis nt
    obj-c obj-c++ objc objective-c++ objectivec ocaml openscad osascript oxygene p21 parser3 pas pascal patch pb pbi
    pcmk pde perl pf pf.conf pgsql php php-template pl plaintext plist pluto pm podspec pony postgres
    postgresql powershell pp processing profile prolog properties proto protobuf ps ps1 puppet purebasic pwsh py pycon
    python python-repl q qml qt r rb re reasonml rib roboconf routeros rs rsl rss ruby
    ruleslanguage rust sas scad scala scheme sci scilab scm scss sh shell shellsession smali smalltalk sml
    sqf sql st stan stanfuncs stata step step21 stp styl stylus subunit sv svg svh swift
    taggerscript tao tap tcl tex text thor thrift tk toml tp ts tsx twig txt typescript
    v vala vb vbnet vbs vbscript vbscript-html verilog vhdl vim wasm wildfly-cli wl wren wsf x++
    x86asm xhtml xjb xl xls xlsx xml xpath xq xqm xquery xsd xsl yaml yml zep
    zephir zone zsh
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    private static func supportedLanguage(_ language: String?, code: String) -> String? {
        // shortcut: fences above 64 KiB keep their raw code without highlighting; raise only after measuring engine cost and cache memory.
        guard let language = language?.lowercased(), languages.contains(language), code.utf8.count <= 65_536 else { return nil }
        return language
    }

    private static func cacheKey(code: String, language: String, isDark: Bool) -> String {
        "\(isDark ? 1 : 0)|\(language)|\(code)"
    }

    private init() {}

    /// Native token colors for TextKit and rich export; keeps the caller's font.
    public func highlightedNative(code: String, language: String?, isDark: Bool) async -> NSAttributedString? {
        guard let language = Self.supportedLanguage(language, code: code) else { return nil }
        let key = Self.cacheKey(code: code, language: language, isDark: isDark)
        if let hit = nativeCache.object(forKey: key as NSString) { return hit.attributed }
        let cached: Cached? = await withCheckedContinuation { continuation in
            queue.async {
                let nsKey = key as NSString
                if let hit = self.nativeCache.object(forKey: nsKey) {
                    continuation.resume(returning: hit)
                    return
                }
                guard let engine = self.engine(isDark: isDark),
                      let raw = engine.highlight(code, as: language, fastRender: true) else {
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
                let entry = Cached(result.copy() as! NSAttributedString)
                self.nativeCache.setObject(entry, forKey: nsKey)
                continuation.resume(returning: entry)
            }
        }
        return cached?.attributed
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
