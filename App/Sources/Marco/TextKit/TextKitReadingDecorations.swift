import AppKit
import ImageIO
import MarcoRendering

// Custom drawing for the M6 TextKit 2 reading surface: code-block cards,
// blockquote bars, and lazily-decoded downsampled images — all painted by a
// single `NSTextLayoutFragment` subclass (Apple's `BubbleLayoutFragment`
// sample pattern, the one M6-PLAN §1 cites). Inline-code chips are a flat
// background attribute (sanctioned by the slice brief) rather than a fragment
// draw, so the fragment only handles block-level chrome + images.

// MARK: - Custom attributes

extension NSAttributedString.Key {
    /// Present on every character line of a code block. Value: `CodeCardEdge`.
    static let marcoCodeCard = NSAttributedString.Key("marco.reading.codeCard")
    /// Present on blockquote lines. Value: `NSNumber` nesting depth (>= 1).
    static let marcoQuoteDepth = NSAttributedString.Key("marco.reading.quoteDepth")
    /// Present on an image line. Value: `MarcoImageDecoration`.
    static let marcoImage = NSAttributedString.Key("marco.reading.image")
    /// Present on an inline-code chip. Value: `NSString` — the code text to copy
    /// on click. Kept off `.link` so TextKit's default blue/underline link
    /// decoration never lands on a code chip.
    static let marcoCopyText = NSAttributedString.Key("marco.reading.copyText")
}

/// Which corners/edges of the continuous code card this line paints. A fenced
/// block is several paragraphs (= several fragments); only the first rounds
/// the top and only the last rounds the bottom, so the stack reads as one card.
struct CodeCardEdge: OptionSet {
    let rawValue: Int
    static let top = CodeCardEdge(rawValue: 1 << 0)
    static let bottom = CodeCardEdge(rawValue: 1 << 1)
}

/// Carried on an image line so the fragment can reserve height (from the cheap
/// pixel-dimension read done at style time — no bitmap decode) and draw the
/// downsampled bitmap lazily when the fragment first paints (per-viewport).
final class MarcoImageDecoration: NSObject {
    let url: URL
    let alt: String
    /// Display size in points, computed at style time from the image's pixel
    /// dimensions (via `ImageIO`, no full decode) fitted to the column.
    let displaySize: CGSize
    init(url: URL, alt: String, displaySize: CGSize) {
        self.url = url
        self.alt = alt
        self.displaySize = displaySize
    }
}

// MARK: - Palette (NSColor snapshot of the current Theme's decoration tokens)

/// AppKit-side snapshot of the `Theme` tokens the fragment needs at draw time.
/// Built once per (re)style so the fragment does no SwiftUI `Color` bridging on
/// the paint path.
struct ReadingDecorationPalette {
    let codeCardFill: NSColor
    let codeCardStroke: NSColor
    let quoteBar: NSColor
    let imageStroke: NSColor

    init(theme: Theme) {
        codeCardFill = NSColor(theme.codeCardFill)
        codeCardStroke = NSColor(theme.codeCardStroke)
        quoteBar = NSColor(theme.quoteBar)
        imageStroke = NSColor(theme.codeCardStroke)
    }
}

// MARK: - Image decode/measure

enum ReadingImageStore {
    /// Cheap: reads pixel dimensions without decoding the bitmap. Returns nil
    /// for unreadable / non-image files (the source markup then just shows as
    /// text, no reserved space).
    static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat,
              w > 0, h > 0
        else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Lazily decoded + downsampled bitmaps, keyed by "url|w|h". Decode happens
    /// only when a fragment first draws (i.e. scrolls into view), never eagerly
    /// for the whole document — the fix for M6-PLAN §8 risk 4 / BENCHMARKS'
    /// Phase-0 image regression.
    // NSCache is internally thread-safe; the `unsafe` here only silences the
    // Sendable check on the shared static (decode happens on the main thread
    // from the fragment's draw).
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 64
        return c
    }()

    static func downsampledImage(url: URL, pointSize: CGSize, scale: CGFloat) -> NSImage? {
        let pixelMax = Int(max(pointSize.width, pointSize.height) * max(scale, 1))
        let key = "\(url.absoluteString)|\(pixelMax)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pixelMax, 1),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: pointSize)
        cache.setObject(image, forKey: key)
        return image
    }
}

// MARK: - Layout fragment

/// Paints block-level chrome behind/around its paragraph, then defers to the
/// default glyph drawing. Height is extended for image lines so the following
/// content flows below the picture.
final class MarcoReadingLayoutFragment: NSTextLayoutFragment {
    var palette: ReadingDecorationPalette
    /// Horizontal inset from the text-container edge to the card/rule edges, so
    /// chrome lines up with the text column rather than the container.
    var contentInset: CGFloat = 0
    var backingScale: CGFloat = 2
    /// The text container's width, pushed in by the delegate (the fragment has
    /// no direct route to its container).
    var columnWidth: CGFloat = 0

    init(textElement: NSTextElement, range: NSTextRange?, palette: ReadingDecorationPalette) {
        self.palette = palette
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private var attributes: [NSAttributedString.Key: Any]? {
        guard let paragraph = textElement as? NSTextParagraph,
              paragraph.attributedString.length > 0 else { return nil }
        return paragraph.attributedString.attributes(at: 0, effectiveRange: nil)
    }

    private var imageDecoration: MarcoImageDecoration? {
        attributes?[.marcoImage] as? MarcoImageDecoration
    }

    // Extend the fragment's height to make room for a picture drawn under the
    // (source) text line.
    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        if let image = imageDecoration {
            frame.size.height += image.displaySize.height + Self.imageGap * 2
        }
        return frame
    }

    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        if let image = imageDecoration {
            let extra = image.displaySize.height + Self.imageGap * 2
            bounds.size.height = max(bounds.size.height, super.layoutFragmentFrame.height + extra)
            // Card / bar draws can bleed a couple points past the glyph box.
            bounds = bounds.insetBy(dx: -8, dy: 0)
        }
        return bounds
    }

    static let imageGap: CGFloat = 8

    override func draw(at renderPoint: CGPoint, in context: CGContext) {
        let attrs = attributes
        let textFrame = super.layoutFragmentFrame

        // Background chrome (card fill, quote bar) goes BEHIND the glyphs, so
        // draw it first — translate so `layoutFragmentFrame`'s absolute
        // container coordinates map onto where `renderPoint` will place the
        // glyphs, draw, then restore before the glyph pass.
        context.saveGState()
        context.translateBy(x: renderPoint.x - textFrame.minX, y: renderPoint.y - textFrame.minY)
        if let edgeRaw = (attrs?[.marcoCodeCard] as? NSNumber)?.intValue {
            drawCodeCard(edge: CodeCardEdge(rawValue: edgeRaw), textFrame: textFrame, in: context)
        }
        if let depth = (attrs?[.marcoQuoteDepth] as? NSNumber)?.intValue, depth >= 1 {
            drawQuoteBars(depth: depth, textFrame: textFrame, in: context)
        }
        context.restoreGState()

        // Glyphs.
        super.draw(at: renderPoint, in: context)

        // Foreground content that sits below the text line (the picture).
        if let image = attrs?[.marcoImage] as? MarcoImageDecoration {
            context.saveGState()
            context.translateBy(x: renderPoint.x - textFrame.minX, y: renderPoint.y - textFrame.minY)
            drawImage(image, textFrame: textFrame, in: context)
            context.restoreGState()
        }
    }

    // MARK: draws

    private func cardRect(textFrame: CGRect) -> CGRect {
        // Full column width (container width minus symmetric content inset),
        // in absolute container coordinates.
        let containerWidth = columnWidth > 0 ? columnWidth : textFrame.width
        let width = max(0, containerWidth - contentInset * 2)
        return CGRect(x: contentInset, y: textFrame.minY, width: width, height: textFrame.height)
    }

    private func drawCodeCard(edge: CodeCardEdge, textFrame: CGRect, in context: CGContext) {
        let rect = cardRect(textFrame: textFrame)
        let radius: CGFloat = 10
        context.saveGState()
        let fillPath = cardPath(rect: rect, radius: radius, edge: edge)
        context.addPath(fillPath)
        context.setFillColor(palette.codeCardFill.cgColor)
        context.fillPath()

        // Stroke: left/right always; top on first line, bottom on last.
        context.setStrokeColor(palette.codeCardStroke.cgColor)
        context.setLineWidth(1)
        let inset = rect.insetBy(dx: 0.5, dy: 0)
        let strokePath = CGMutablePath()
        strokePath.move(to: CGPoint(x: inset.minX, y: rect.minY))
        strokePath.addLine(to: CGPoint(x: inset.minX, y: rect.maxY))
        strokePath.move(to: CGPoint(x: inset.maxX, y: rect.minY))
        strokePath.addLine(to: CGPoint(x: inset.maxX, y: rect.maxY))
        if edge.contains(.top) {
            strokePath.move(to: CGPoint(x: inset.minX, y: rect.minY + 0.5))
            strokePath.addLine(to: CGPoint(x: inset.maxX, y: rect.minY + 0.5))
        }
        if edge.contains(.bottom) {
            strokePath.move(to: CGPoint(x: inset.minX, y: rect.maxY - 0.5))
            strokePath.addLine(to: CGPoint(x: inset.maxX, y: rect.maxY - 0.5))
        }
        context.addPath(strokePath)
        context.strokePath()
        context.restoreGState()
    }

    /// A rect whose top corners round only when `.top` is set and bottom only
    /// when `.bottom` is set (square everywhere else), so stacked line
    /// fragments merge into one continuous card.
    private func cardPath(rect: CGRect, radius: CGFloat, edge: CodeCardEdge) -> CGPath {
        let path = CGMutablePath()
        let tl = edge.contains(.top) ? radius : 0
        let tr = tl
        let bl = edge.contains(.bottom) ? radius : 0
        let br = bl
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.minY + tr), radius: tr)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX - br, y: rect.maxY), radius: br)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bl), radius: bl)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.minX + tl, y: rect.minY), radius: tl)
        path.closeSubpath()
        return path
    }

    private func drawQuoteBars(depth: Int, textFrame: CGRect, in context: CGContext) {
        context.saveGState()
        context.setFillColor(palette.quoteBar.cgColor)
        let barWidth: CGFloat = 2
        let step = MarcoReadingMetrics.quoteIndent
        for level in 0..<depth {
            let x = contentInset + step * CGFloat(level)
            let rect = CGRect(x: x, y: textFrame.minY, width: barWidth, height: textFrame.height)
            let bar = CGPath(roundedRect: rect, cornerWidth: 1, cornerHeight: 1, transform: nil)
            context.addPath(bar)
            context.fillPath()
        }
        context.restoreGState()
    }

    private func drawImage(_ image: MarcoImageDecoration, textFrame: CGRect, in context: CGContext) {
        let top = textFrame.maxY + Self.imageGap
        let containerWidth = columnWidth > 0 ? columnWidth : textFrame.width
        let available = max(0, containerWidth - contentInset * 2)
        let width = min(image.displaySize.width, available)
        let height = image.displaySize.height * (width / max(image.displaySize.width, 1))
        let x = contentInset
        let rect = CGRect(x: x, y: top, width: width, height: height)

        guard let bitmap = ReadingImageStore.downsampledImage(
            url: image.url, pointSize: CGSize(width: width, height: height), scale: backingScale)
        else {
            // Unreadable: a quiet placeholder card so layout stays stable.
            context.saveGState()
            context.setFillColor(palette.codeCardFill.cgColor)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
            context.fillPath()
            context.restoreGState()
            return
        }

        context.saveGState()
        let clip = CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil)
        context.addPath(clip)
        context.clip()
        var proposed = rect
        if let cg = bitmap.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
            context.draw(cg, in: rect)
        }
        context.restoreGState()

        context.saveGState()
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 10, cornerHeight: 10, transform: nil))
        context.setStrokeColor(palette.imageStroke.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()
    }
}

/// Hands back the decorating fragment for every paragraph (cheap — TextKit 2
/// only builds fragments for the visible viewport). Retained by the view's
/// coordinator because `NSTextLayoutManager.delegate` is weak.
final class MarcoReadingLayoutManagerDelegate: NSObject, NSTextLayoutManagerDelegate {
    var palette: ReadingDecorationPalette
    var contentInset: CGFloat = 0
    var backingScale: CGFloat = 2

    init(palette: ReadingDecorationPalette) { self.palette = palette }

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let fragment = MarcoReadingLayoutFragment(
            textElement: textElement, range: textElement.elementRange, palette: palette)
        fragment.contentInset = contentInset
        fragment.backingScale = backingScale
        fragment.columnWidth = textLayoutManager.textContainer?.size.width ?? 0
        return fragment
    }
}
