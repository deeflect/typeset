import AppKit

/// TextKit 1 block that draws the board's code card, quote bar, rule, MDX frame or fill box behind its paragraphs.
/// Chrome (language label, "Copy", MDX tag) is drawn, not text, so it never lands in a selection.
final class TypesetTextBlock: NSTextBlock {
    /// `rule(length:)` nil spans the measure; footnotes use a 120 pt hairline.
    /// `frame` is an MDX container (hairline, tag on top); `box` a filled card (raw YAML, MDX placeholders).
    enum Kind { case code(language: String?), quote, rule(length: CGFloat?, above: CGFloat, below: CGFloat), frame(tag: String), box(radius: CGFloat, padY: CGFloat) }
    /// Code card's Copy slot: idle, hovered (button fill), or confirming a copy.
    enum CopyState { case idle, hover, copied }
    let kind: Kind
    var copyState: CopyState = .idle
    private let color: NSColor
    private let scale: CGFloat

    init(_ kind: Kind, color: NSColor, scale: CGFloat) {
        self.kind = kind
        self.color = color
        self.scale = scale
        super.init()
        // Without an explicit width TextKit 1 skips block layout (no padding, no drawBackground).
        setValue(100, type: .percentageValueType, for: .width)
        switch kind {
        case .code:
            // R01: a card without a language drops the header row (14 all round); else 14 pad + 13 header + 8 gap.
            setWidth((hasHeader ? 35 : 14) * scale, type: .absoluteValueType, for: .padding, edge: .minY)
            setWidth(14 * scale, type: .absoluteValueType, for: .padding, edge: .maxY)
            setWidth(16 * scale, type: .absoluteValueType, for: .padding, edge: .minX)
            setWidth((hasHeader ? 16 : 84) * scale, type: .absoluteValueType, for: .padding, edge: .maxX)
            setWidth(16 * scale, type: .absoluteValueType, for: .margin, edge: .maxY)
        case .quote:
            setWidth(17 * scale, type: .absoluteValueType, for: .padding, edge: .minX) // 3 bar + 14 gap
            setWidth(2 * scale, type: .absoluteValueType, for: .padding, edge: .minY)
            setWidth(2 * scale, type: .absoluteValueType, for: .padding, edge: .maxY)
            setWidth(16 * scale, type: .absoluteValueType, for: .margin, edge: .maxY)
        case .rule(_, let above, let below):
            setWidth(above * scale, type: .absoluteValueType, for: .margin, edge: .minY)
            setWidth(below * scale, type: .absoluteValueType, for: .margin, edge: .maxY)
        case .frame:
            setWidth(32 * scale, type: .absoluteValueType, for: .padding, edge: .minY) // 10 pad + 14 tag + 8 gap
            setWidth(14 * scale, type: .absoluteValueType, for: .padding, edge: .maxY)
            setWidth(16 * scale, type: .absoluteValueType, for: .padding, edge: .minX)
            setWidth(16 * scale, type: .absoluteValueType, for: .padding, edge: .maxX)
            setWidth(16 * scale, type: .absoluteValueType, for: .margin, edge: .maxY)
        case .box(let radius, let padY):
            let padX: CGFloat = radius >= 8 ? 14 : 12
            setWidth(padY * scale, type: .absoluteValueType, for: .padding, edge: .minY)
            setWidth(padY * scale, type: .absoluteValueType, for: .padding, edge: .maxY)
            setWidth(padX * scale, type: .absoluteValueType, for: .padding, edge: .minX)
            setWidth(padX * scale, type: .absoluteValueType, for: .padding, edge: .maxX)
            setWidth(16 * scale, type: .absoluteValueType, for: .margin, edge: .maxY)
        }
    }

    required init?(coder: NSCoder) { nil }

    private var hasHeader: Bool {
        if case .code(let language) = kind { return !(language ?? "").isEmpty }
        return false
    }
    private func labelAttrs(_ color: NSColor, weight: NSFont.Weight = .regular) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 11 * scale, weight: weight), .foregroundColor: color]
    }

    /// R03 Copy slot: 68 wide, 3/6 padding, radius 5; for a block laid out in `frameRect` (the rect TextKit
    /// hands `drawBackground`). Fixed width so "Copy" → "Copied" never shifts. Without a header it sits
    /// centred on the first 21 pt code line.
    func copyHitRect(inFrame frameRect: NSRect) -> NSRect {
        let right = frameRect.maxX - width(for: .margin, edge: .maxX) - 10 * scale
        let top = frameRect.minY + width(for: .margin, edge: .minY) + (hasHeader ? 11 : 14.5) * scale
        return NSRect(x: right - 68 * scale, y: top, width: 68 * scale, height: 20 * scale)
    }

    // Paragraphs are grouped into one block by identity; a copy would split the card per line.
    override func copy(with zone: NSZone? = nil) -> Any { self }

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?, characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        let rect = NSRect(
            x: frameRect.minX + width(for: .margin, edge: .minX),
            y: frameRect.minY + width(for: .margin, edge: .minY),
            width: frameRect.width - width(for: .margin, edge: .minX) - width(for: .margin, edge: .maxX),
            height: frameRect.height - width(for: .margin, edge: .minY) - width(for: .margin, edge: .maxY))
        switch kind {
        case .code(let language):
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8 * scale, yRadius: 8 * scale).fill()
            if let language, !language.isEmpty {
                (language as NSString).draw(at: NSPoint(x: rect.minX + 16 * scale, y: rect.minY + 14 * scale), withAttributes: labelAttrs(.tertiaryLabelColor))
            }
            drawCopy(in: copyHitRect(inFrame: frameRect))
        case .quote:
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: 3 * scale, height: rect.height), xRadius: 1.5 * scale, yRadius: 1.5 * scale).fill()
        case .rule(let length, _, _):
            color.setFill()
            NSRect(x: rect.minX, y: rect.midY.rounded(), width: length.map { $0 * scale } ?? rect.width, height: 1).fill()
        case .frame(let tag):
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8 * scale, yRadius: 8 * scale)
            path.lineWidth = 1
            color.setStroke()
            path.stroke()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11 * scale, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]
            (tag as NSString).draw(at: NSPoint(x: rect.minX + 16 * scale, y: rect.minY + 10 * scale), withAttributes: attrs)
        case .box(let radius, _):
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius * scale, yRadius: radius * scale).fill()
        }
    }

    /// Rest: tertiary doc.on.doc + "Copy". Hover: fill + secondary. Copied: accent checkmark + "Copied", no fill.
    private func drawCopy(in slot: NSRect) {
        if copyState == .hover {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: slot, xRadius: 5 * scale, yRadius: 5 * scale).fill()
        }
        let tint: NSColor = switch copyState {
        case .idle: .tertiaryLabelColor
        case .hover: .secondaryLabelColor
        case .copied: .controlAccentColor
        }
        let label = (copyState == .copied ? "Copied" : "Copy") as NSString
        let attrs = labelAttrs(tint, weight: copyState == .copied ? .medium : .regular)
        let size = label.size(withAttributes: attrs)
        let symbolName = copyState == .copied ? "checkmark" : "doc.on.doc"
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10 * scale, weight: copyState == .copied ? .semibold : .regular).applying(.init(paletteColors: [tint])))
        let glyph = symbol?.size ?? .zero
        let gap = 4 * scale
        var x = slot.maxX - 6 * scale - size.width - gap - glyph.width
        symbol?.draw(in: NSRect(x: x, y: slot.midY - glyph.height / 2, width: glyph.width, height: glyph.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        x += glyph.width + gap
        label.draw(at: NSPoint(x: x, y: slot.midY - size.height / 2), withAttributes: attrs)
    }
}

/// 16 pt task box: accent fill + white check, or page fill with a gray-3 stroke.
final class CheckboxCell: NSTextAttachmentCell {
    private let checked: Bool
    private let side: CGFloat
    private let stroke: NSColor
    /// Set while hovered (R04): stroke steps to #8E8E93 and a 3 pt accent-soft ring is drawn.
    var hoverRing: NSColor?

    init(checked: Bool, side: CGFloat, stroke: NSColor) {
        self.checked = checked
        self.side = side
        self.stroke = stroke
        super.init(textCell: "")
    }
    required init(coder: NSCoder) { fatalError("not coded") }

    override func cellSize() -> NSSize { NSSize(width: side, height: side) }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -side * 0.19) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let box = NSRect(x: cellFrame.minX, y: cellFrame.minY, width: side, height: side)
        let radius = side / 4
        if let hoverRing {
            hoverRing.setFill()
            NSBezierPath(roundedRect: box.insetBy(dx: -3, dy: -3), xRadius: radius + 3, yRadius: radius + 3).fill()
        }
        if checked {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
            let flipped = controlView?.isFlipped ?? true
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: box.minX + x * side, y: flipped ? box.minY + y * side : box.maxY - y * side)
            }
            let check = NSBezierPath()
            check.move(to: point(0.27, 0.52))
            check.line(to: point(0.43, 0.68))
            check.line(to: point(0.74, 0.35))
            check.lineWidth = side * 0.12
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
        } else {
            let inset = box.insetBy(dx: 0.75, dy: 0.75)
            let path = NSBezierPath(roundedRect: inset, xRadius: radius - 0.75, yRadius: radius - 0.75)
            NSColor.textBackgroundColor.setFill()
            path.fill()
            path.lineWidth = 1.5
            (hoverRing == nil ? stroke : NSColor(white: 0x8E / 255.0, alpha: 1)).setStroke()
            path.stroke()
        }
    }
}

/// Toggle chevron mid-rotation (R04): closed points right (0°), open points down (90°).
final class ChevronCell: NSTextAttachmentCell {
    var angle: CGFloat
    private let color: NSColor
    private let scale: CGFloat
    private let baseline: CGFloat

    init(angle: CGFloat, color: NSColor, scale: CGFloat, baseline: CGFloat) {
        self.angle = angle
        self.color = color
        self.scale = scale
        self.baseline = baseline
        super.init(textCell: "")
    }
    required init(coder: NSCoder) { fatalError("not coded") }

    override func cellSize() -> NSSize { NSSize(width: 14 * scale, height: 10 * scale) }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: baseline) }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: cellFrame.minX, yBy: cellFrame.minY)
        t.scale(by: scale)
        t.concat()
        Self.stroke(angle: angle, color: color)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The right-pointing chevron in a flipped 14×10 box, turned `angle` degrees clockwise about its center.
    nonisolated static func stroke(angle: CGFloat, color: NSColor) {
        let r = angle * .pi / 180
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: 7 + x * cos(r) - y * sin(r), y: 5 + x * sin(r) + y * cos(r))
        }
        let path = NSBezierPath()
        path.move(to: p(-1.5, -3.25)); path.line(to: p(1.75, 0)); path.line(to: p(-1.5, 3.25))
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }
}

/// Full-measure image stand-in (R06): 160 pt card shown until the file decodes, and kept
/// with an explanation when it can't (web image, outside the granted folder, or missing).
final class ImagePlaceholderCell: NSTextAttachmentCell {
    enum State: Equatable { case loading, remote(String), blocked, missing }
    var loadState: State
    private let name: String
    private let fill: NSColor
    private let buttonStroke: NSColor
    private let scale: CGFloat

    init(name: String, state: State, fill: NSColor, buttonStroke: NSColor, scale: CGFloat) {
        self.name = name
        self.loadState = state
        self.fill = fill
        self.buttonStroke = buttonStroke
        self.scale = scale
        super.init(textCell: "")
    }
    required init(coder: NSCoder) { fatalError("not coded") }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        NSRect(x: 0, y: 0, width: max(120, lineFrag.width - position.x), height: 160 * scale)
    }

    private enum Item { case icon, text(String, NSFont, NSColor), button(String) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        fill.setFill()
        NSBezierPath(roundedRect: cellFrame, xRadius: 8 * scale, yRadius: 8 * scale).fill()

        let app = Bundle.main.displayName
        let title = NSFont.systemFont(ofSize: 13 * scale, weight: .semibold)
        let small = NSFont.systemFont(ofSize: 12 * scale)
        // (item, gap before it); only the secondary helper line wraps. R06 columns are gap 4; loading is gap 8; the button adds an 8 margin.
        let items: [(Item, CGFloat)] = switch loadState {
        case .loading: [(.icon, 0), (.text(name, small, .tertiaryLabelColor), 8)]
        case .remote(let address): [
            (.text("Web image not loaded", title, .labelColor), 0),
            (.text("\(app) only shows images stored on this Mac", small, .secondaryLabelColor), 4),
            (.text(address, NSFont.systemFont(ofSize: 11 * scale), .tertiaryLabelColor), 8)]
        case .blocked: [
            (.text("\(app) can\u{2019}t show \(name)", title, .labelColor), 0),
            (.text("It\u{2019}s outside this file\u{2019}s folder", small, .secondaryLabelColor), 4),
            (.button("Allow Access\u{2026}"), 12)]
        case .missing: [
            (.text("\(app) can\u{2019}t find \(name)", title, .labelColor), 0),
            (.text("Check the path in the file", small, .secondaryLabelColor), 4)]
        }
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let textWidth = cellFrame.width - 32 * scale
        func attrs(_ font: NSFont, _ color: NSColor, wrap: Bool) -> [NSAttributedString.Key: Any] {
            let p = centered.mutableCopy() as! NSMutableParagraphStyle
            p.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingMiddle
            // Line heights 13/18, 12/16, 11/14.
            p.minimumLineHeight = font.pointSize >= 13 * scale ? 18 * scale : font.pointSize >= 12 * scale ? 16 * scale : 14 * scale
            p.maximumLineHeight = p.minimumLineHeight
            return [.font: font, .foregroundColor: color, .paragraphStyle: p]
        }
        func height(_ item: Item) -> CGFloat {
            switch item {
            case .icon: 16 * scale
            case .button: 26 * scale
            case .text(let string, let font, let color):
                ceil((string as NSString).boundingRect(with: NSSize(width: textWidth, height: 1000), options: [.usesLineFragmentOrigin],
                                                        attributes: attrs(font, color, wrap: color == .secondaryLabelColor)).height)
            }
        }
        let total = items.reduce(0) { $0 + $1.1 + height($1.0) }
        let flipped = controlView?.isFlipped ?? true
        var y = cellFrame.midY - total / 2 // running top edge, in flipped terms
        func frame(_ width: CGFloat, _ h: CGFloat) -> NSRect {
            let top = flipped ? y : cellFrame.maxY - (y - cellFrame.minY) - h
            return NSRect(x: cellFrame.midX - width / 2, y: top, width: width, height: h)
        }
        for (item, gap) in items {
            y += gap
            let h = height(item)
            switch item {
            case .icon:
                // A 20×16 frame, 1.5 stroke, radius 3, ink-3.
                let path = NSBezierPath(roundedRect: frame(20 * scale, h).insetBy(dx: 0.75 * scale, dy: 0.75 * scale), xRadius: 3 * scale, yRadius: 3 * scale)
                path.lineWidth = 1.5 * scale
                NSColor.tertiaryLabelColor.setStroke()
                path.stroke()
            case .text(let string, let font, let color):
                (string as NSString).draw(with: frame(textWidth, h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                          attributes: attrs(font, color, wrap: color == .secondaryLabelColor))
            case .button(let string):
                // 4/10 padding + 1 pt border, radius 6, page fill.
                let label = string as NSString
                let labelAttrs = attrs(small, .labelColor, wrap: false)
                let width = ceil(label.size(withAttributes: labelAttrs).width) + 22 * scale
                let rect = frame(width, h)
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6 * scale, yRadius: 6 * scale)
                NSColor.textBackgroundColor.setFill()
                path.fill()
                buttonStroke.setStroke()
                path.lineWidth = 1
                path.stroke()
                label.draw(with: rect.insetBy(dx: 0, dy: 5 * scale), options: [.usesLineFragmentOrigin], attributes: labelAttrs)
            }
            y += h
        }
    }
}

/// A decoded image (R06 loaded): radius 8 + hairline; `alpha` drives the 0.22 arrival fade.
final class LoadedImageCell: NSTextAttachmentCell {
    var hairline: NSColor = .clear
    var alpha: CGFloat = 1

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let image else { return }
        let path = NSBezierPath(roundedRect: cellFrame, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        image.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        let edge = NSBezierPath(roundedRect: cellFrame.insetBy(dx: 0.5, dy: 0.5), xRadius: 7.5, yRadius: 7.5)
        edge.lineWidth = 1
        hairline.withAlphaComponent(hairline.alphaComponent * alpha).setStroke()
        edge.stroke()
    }
}

/// Draws inline-code chips (R01/R03: radius 5, 22 pt tall at 15 pt mono) and `<kbd>` keycaps instead of
/// TextKit's flat background rects. Hover and the copy flash are draw-time state only, never layout.
final class ChipLayoutManager: NSLayoutManager {
    var hoveredChip: NSRange?
    /// Hovered `<details>` summary row (R04) and its fill.
    var hoveredRow: NSRange?
    var rowFill: NSColor = .clear
    var flashChip: NSRange?
    var flashAlpha: CGFloat = 0
    var hoverFill: NSColor = .clear
    var flashFill: NSColor = .clear
    /// The text view's container origin, refreshed before each draw (rects arrive in view coordinates).
    var containerOrigin: NSPoint = .zero

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let row = hoveredRow, let container = textContainers.first else { return }
        let glyphs = glyphRange(forCharacterRange: row, actualCharacterRange: nil)
        guard NSIntersectionRange(glyphs, glyphsToShow).length > 0 else { return }
        let rect = boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -8, dy: -3)
        rowFill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        guard let storage = textStorage, charRange.location < storage.length,
              let fill = storage.attribute(.backgroundColor, at: charRange.location, effectiveRange: nil) as? NSColor, fill == color,
              let font = storage.attribute(.font, at: charRange.location, effectiveRange: nil) as? NSFont,
              let container = textContainers.first else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        let keycap = storage.attribute(.typesetKeycap, at: charRange.location, effectiveRange: nil) as? NSColor
        let origin = containerOrigin
        let pad = (storage.attribute(.kern, at: NSMaxRange(charRange) - 1, effectiveRange: nil) as? CGFloat) ?? 0
        let height = (font.pointSize * 22 / 15).rounded()
        for index in 0..<rectCount {
            let rect = rectArray[index]
            let glyph = glyphIndex(for: NSPoint(x: rect.midX - origin.x, y: rect.midY - origin.y), in: container)
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = fragment.minY + location(forGlyphAt: glyph).y + origin.y
            let center = baseline - (font.ascender + font.descender) / 2
            let chip = NSRect(x: rect.minX - pad, y: (center - height / 2).rounded(), width: rect.width + pad, height: height)
            if let keycap {
                keycap.setFill()
                NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: chip.minX + 1, y: chip.minY + 1, width: chip.width - 2, height: chip.height - 3), xRadius: 3, yRadius: 3).fill()
                continue
            }
            let path = NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5)
            let hovered = hoveredChip.map { NSIntersectionRange($0, charRange).length > 0 } ?? false
            (hovered ? hoverFill : color).setFill()
            path.fill()
            if flashAlpha > 0, let flashChip, NSIntersectionRange(flashChip, charRange).length > 0 {
                flashFill.withAlphaComponent(flashFill.alphaComponent * flashAlpha).setFill()
                path.fill()
            }
        }
    }
}
