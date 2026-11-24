import AppKit
import Mermaid
import SwiftMath

/// Offline, sandbox-safe renderer for Mermaid diagrams (`swift-mermaid`) and
/// LaTeX math (`SwiftMath`), using pure Swift + CoreGraphics/CoreText with zero
/// WebKit or network entitlements.
public final class DiagramRenderer: @unchecked Sendable {
    public enum Kind: Hashable, Sendable { case mermaid, displayMath, inlineMath }

    public enum Result: @unchecked Sendable {
        /// `descent` is how far an inline formula sits below the text baseline.
        case image(NSImage, png: Data?, descent: CGFloat)
        case failure(String)
    }

    public static let shared = DiagramRenderer()

    private let queue = DispatchQueue(label: "com.deeflect.typeset.diagrams", qos: .userInitiated)
    nonisolated(unsafe) private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    private final class Box: NSObject, @unchecked Sendable {
        let result: Result
        init(_ result: Result) { self.result = result }
    }

    private init() {}

    public func render(_ source: String, kind: Kind, isDark: Bool, fontSize: CGFloat) async -> Result {
        let key = "\(kind)|\(isDark)|\(Int(fontSize.rounded()))|\(source)"
        if let hit = cache.object(forKey: key as NSString) { return hit.result }
        return await withCheckedContinuation { continuation in
            queue.async {
                let nsKey = key as NSString
                if let hit = self.cache.object(forKey: nsKey) {
                    continuation.resume(returning: hit.result)
                    return
                }
                let result = Self.renderSync(source, kind: kind, isDark: isDark, fontSize: fontSize)
                let cost: Int
                switch result {
                case .image(let image, let png, _):
                    cost = Int(image.size.width * image.size.height * 16) + (png?.count ?? 0)
                case .failure:
                    cost = 1024
                }
                self.cache.setObject(Box(result), forKey: nsKey, cost: cost)
                continuation.resume(returning: result)
            }
        }
    }

    private static func renderSync(_ source: String, kind: Kind, isDark: Bool, fontSize: CGFloat) -> Result {
        switch kind {
        case .mermaid:
            return renderMermaidSync(source, isDark: isDark)
        case .displayMath, .inlineMath:
            return renderMathSync(source, display: kind == .displayMath, isDark: isDark, fontSize: fontSize)
        }
    }

    private static func renderMermaidSync(_ source: String, isDark: Bool) -> Result {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure("Empty Mermaid diagram.") }
        do {
            let scene = try Mermaid.render(trimmed, theme: isDark ? .dark : .default)
            guard let cg = scene.cgImage(scale: 2) else {
                return .failure("The diagram came out empty.")
            }
            let image = NSImage(cgImage: cg, size: scene.size)
            let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            return .image(image, png: png, descent: 0)
        } catch let error as MermaidError {
            return .failure(error.description)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func renderMathSync(_ source: String, display: Bool, isDark: Bool, fontSize: CGFloat) -> Result {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure("Empty formula.") }
        let targetSize = max(10, fontSize * (display ? 1.2 : 1.1))
        // Match macOS labelColor in light/dark without touching main-actor NSAppearance.
        let color = isDark
            ? NSColor(srgbRed: 0.92, green: 0.92, blue: 0.94, alpha: 1)
            : NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        let pad: CGFloat = 2
        var mathImage = MathImage(
            latex: trimmed,
            fontSize: targetSize,
            textColor: color,
            labelMode: display ? .display : .text,
            textAlignment: .left
        )
        mathImage.contentInsets = NSEdgeInsets(top: pad, left: pad, bottom: pad, right: pad)
        let (error, vectorImage, layoutInfo) = mathImage.asImage()
        if let error {
            return .failure(error.localizedDescription)
        }
        guard let vectorImage else {
            return .failure("Could not typeset formula.")
        }

        let size = NSSize(width: max(1, ceil(vectorImage.size.width)), height: max(1, ceil(vectorImage.size.height)))
        let scale: CGFloat = 2
        let pixelWidth = max(1, Int(size.width * scale))
        let pixelHeight = max(1, Int(size.height * scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return .failure("Could not create math canvas.")
        }

        ctx.scaleBy(x: scale, y: scale)
        let nsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = nsContext
        vectorImage.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        nsContext.flushGraphics()
        NSGraphicsContext.current = previous

        guard let cg = ctx.makeImage() else { return .failure("Could not rasterize formula.") }
        let image = NSImage(cgImage: cg, size: size)
        let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        let descent = max(0, ceil((layoutInfo?.descent ?? 0) + pad))
        return .image(image, png: png, descent: display ? 0 : descent)
    }
}

enum NativeMarkdownMath {
    enum Piece: Equatable { case text(String), math(String) }

    /// Inline `$…$` by GitHub's rule: no space after the opening `$`, none before the closing one,
    /// escaped `\$` stays literal, and the closing `$` isn't followed by a digit (so "$5 and $10" stays prose).
    static func split(_ text: String) -> [Piece] {
        guard text.utf8.contains(UInt8(ascii: "$")) else { return [.text(text)] }
        let chars = Array(text)
        var pieces: [Piece] = []
        var plain = ""
        var i = 0
        while i < chars.count {
            let escaped = i > 0 && chars[i - 1] == "\\"
            if !escaped, chars[i] == "$", i + 1 < chars.count, chars[i + 1] != "$", !chars[i + 1].isWhitespace,
               let close = closingDollar(in: chars, from: i + 2),
               !chars[close - 1].isWhitespace, close + 1 == chars.count || !chars[close + 1].isNumber {
                if !plain.isEmpty { pieces.append(.text(plain)); plain = "" }
                pieces.append(.math(String(chars[(i + 1)..<close])))
                i = close + 1
                continue
            }
            plain.append(chars[i])
            i += 1
        }
        if !plain.isEmpty { pieces.append(.text(plain)) }
        return pieces
    }

    private static func closingDollar(in chars: [Character], from start: Int) -> Int? {
        guard start < chars.count else { return nil }
        for idx in start..<chars.count {
            if chars[idx] == "$", chars[idx - 1] != "\\" { return idx }
        }
        return nil
    }

    /// A paragraph whose whole source is `$$ … $$` is display math.
    static func displayTeX(_ source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 4, trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$") else { return nil }
        let inner = trimmed.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty || inner.contains("$$") ? nil : inner
    }
}

/// Stand-in for a diagram or formula until it renders; also its fallback when it can't.
/// Math draws its raw TeX in secondary color; Mermaid shows an empty card while loading
/// and the error plus source once it fails.
final class DiagramCell: NSTextAttachmentCell {
    enum State { case loading, failed(String) }
    nonisolated(unsafe) var renderState: State = .loading
    let kind: DiagramRenderer.Kind
    private let source: String
    private let fontSize: CGFloat
    private let fill: NSColor
    private let scale: CGFloat

    init(kind: DiagramRenderer.Kind, source: String, fontSize: CGFloat, fill: NSColor, scale: CGFloat) {
        self.kind = kind
        self.source = source
        self.fontSize = fontSize
        self.fill = fill
        self.scale = scale
        super.init(textCell: "")
    }
    required init(coder: NSCoder) { fatalError("not coded") }

    func failed(_ message: String) -> DiagramCell {
        let cell = DiagramCell(kind: kind, source: source, fontSize: fontSize, fill: fill, scale: scale)
        cell.renderState = .failed(message)
        return cell
    }

    nonisolated private var texAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: fontSize * (kind == .inlineMath ? 0.94 : 0.88), weight: .regular),
         .foregroundColor: NSColor.secondaryLabelColor]
    }
    nonisolated private var tex: NSString { (kind == .inlineMath ? "$\(source)$" : source) as NSString }
    nonisolated private var pad: CGFloat { 16 * scale }

    nonisolated private func card(width: CGFloat) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if case .failed(let message) = renderState {
            text.append(NSAttributedString(string: "Couldn\u{2019}t render this diagram\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12 * scale, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor]))
            text.append(NSAttributedString(string: "\(message)\n\n", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11 * scale, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor]))
        }
        text.append(NSAttributedString(string: source, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12.5 * scale, weight: .regular),
            .foregroundColor: NSColor.labelColor]))
        return text
    }

    override func cellBaselineOffset() -> NSPoint {
        kind == .inlineMath ? NSPoint(x: 0, y: NSFont.systemFont(ofSize: fontSize).descender.rounded()) : .zero
    }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let available = max(120, lineFrag.width - position.x)
        switch (kind, renderState) {
        case (.inlineMath, _):
            let size = tex.size(withAttributes: texAttrs)
            let descent = NSFont.systemFont(ofSize: fontSize).descender.rounded()
            return NSRect(x: 0, y: descent, width: ceil(size.width), height: ceil(size.height))
        case (.displayMath, _):
            let size = tex.boundingRect(with: NSSize(width: available, height: 10_000), options: .usesLineFragmentOrigin, attributes: texAttrs)
            return NSRect(x: 0, y: 0, width: min(available, ceil(size.width) + 2), height: ceil(size.height))
        case (.mermaid, .loading):
            return NSRect(x: 0, y: 0, width: available, height: 120 * scale)
        case (.mermaid, .failed):
            let height = card(width: available).boundingRect(with: NSSize(width: max(80, available - 2 * pad), height: 100_000), options: .usesLineFragmentOrigin).height
            return NSRect(x: 0, y: 0, width: available, height: ceil(height) + 2 * pad)
        }
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        switch kind {
        case .inlineMath, .displayMath:
            tex.draw(with: cellFrame, options: .usesLineFragmentOrigin, attributes: texAttrs)
        case .mermaid:
            fill.setFill()
            NSBezierPath(roundedRect: cellFrame, xRadius: 8 * scale, yRadius: 8 * scale).fill()
            if case .failed = renderState {
                card(width: cellFrame.width).draw(with: cellFrame.insetBy(dx: pad, dy: pad), options: .usesLineFragmentOrigin)
            }
        }
    }
}

/// A rendered diagram or formula; inline formulas keep their baseline on the text's,
/// while Mermaid diagrams get subtle rounded framing matching loaded images.
final class DiagramImageCell: NSTextAttachmentCell {
    private let descent: CGFloat
    private let hairline: NSColor?

    init(image: NSImage, descent: CGFloat, hairline: NSColor? = nil) {
        self.descent = descent
        self.hairline = hairline
        super.init(imageCell: image)
    }
    required init(coder: NSCoder) { fatalError("not coded") }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -descent) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let image else { return }
        guard let hairline else {
            image.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        let path = NSBezierPath(roundedRect: cellFrame, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        image.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        let edge = NSBezierPath(roundedRect: cellFrame.insetBy(dx: 0.5, dy: 0.5), xRadius: 7.5, yRadius: 7.5)
        edge.lineWidth = 1
        hairline.setStroke()
        edge.stroke()
    }
}

extension NativeMarkdownDocument.DiagramReference {
    /// Shrinks to `maxWidth`, never enlarges past natural size.
    @MainActor func attachment(for result: DiagramRenderer.Result, maxWidth: CGFloat, existing: NSTextAttachment?, isDark: Bool) -> NSTextAttachment? {
        switch result {
        case .failure(let message):
            // Math keeps its raw-TeX stand-in; a diagram swaps to the error card.
            guard kind == .mermaid, let cell = existing?.attachmentCell as? DiagramCell else { return nil }
            let attachment = NSTextAttachment()
            attachment.attachmentCell = cell.failed(message)
            return attachment
        case .image(let image, let png, let descent):
            let display = image.copy() as! NSImage
            var scale: CGFloat = 1
            if display.size.width > maxWidth {
                scale = maxWidth / display.size.width
                display.size = NSSize(width: maxWidth, height: display.size.height * scale)
            }
            let attachment = NSTextAttachment()
            if let png {
                let wrapper = FileWrapper(regularFileWithContents: png)
                wrapper.preferredFilename = kind == .mermaid ? "diagram.png" : "math.png"
                attachment.fileWrapper = wrapper
            }
            let hairline: NSColor? = kind == .mermaid
                ? NSColor(Theme(colorScheme: isDark ? .dark : .light, scale: 1).hairline)
                : nil
            attachment.attachmentCell = DiagramImageCell(image: display, descent: descent * scale, hairline: hairline)
            return attachment
        }
    }
}
