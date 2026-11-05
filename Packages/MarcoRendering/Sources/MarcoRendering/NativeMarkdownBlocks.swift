import AppKit

/// TextKit 1 block that draws the board's code card, quote bar or rule behind its paragraphs.
/// Chrome (language label, "Copy") is drawn, not text, so it never lands in a selection.
final class MarcoTextBlock: NSTextBlock {
    enum Kind { case code(language: String?), quote, rule }
    /// Code card's Copy label: idle, hovered (button fill), or confirming a copy.
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
            setWidth(35 * scale, type: .absoluteValueType, for: .padding, edge: .minY) // 14 pad + 13 header + 8 gap
            setWidth(14 * scale, type: .absoluteValueType, for: .padding, edge: .maxY)
            setWidth(16 * scale, type: .absoluteValueType, for: .padding, edge: .minX)
            setWidth(16 * scale, type: .absoluteValueType, for: .padding, edge: .maxX)
            setWidth(16 * scale, type: .absoluteValueType, for: .margin, edge: .maxY)
        case .quote:
            setWidth(17 * scale, type: .absoluteValueType, for: .padding, edge: .minX) // 3 bar + 14 gap
            setWidth(2 * scale, type: .absoluteValueType, for: .padding, edge: .minY)
            setWidth(2 * scale, type: .absoluteValueType, for: .padding, edge: .maxY)
            setWidth(16 * scale, type: .absoluteValueType, for: .margin, edge: .maxY)
        case .rule:
            setWidth(16 * scale, type: .absoluteValueType, for: .margin, edge: .maxY)
        }
    }

    required init?(coder: NSCoder) { nil }

    private var copyLabel: String { copyState == .copied ? "Copied" : "Copy" }
    private func labelAttrs(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 11 * scale), .foregroundColor: color]
    }

    /// The Copy label's clickable box, padded around the text, for a block laid out in `frameRect`
    /// (the same rect TextKit hands `drawBackground`). Sized for "Copied" so it doesn't jump.
    func copyHitRect(inFrame frameRect: NSRect) -> NSRect {
        let right = frameRect.maxX - width(for: .margin, edge: .maxX) - 16 * scale
        let top = frameRect.minY + width(for: .margin, edge: .minY) + 14 * scale
        let textWidth = ("Copied" as NSString).size(withAttributes: labelAttrs(.labelColor)).width
        return NSRect(x: right - textWidth - 6 * scale, y: top - 3 * scale, width: textWidth + 12 * scale, height: 19 * scale)
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
            let y = rect.minY + 14 * scale
            if let language, !language.isEmpty {
                (language as NSString).draw(at: NSPoint(x: rect.minX + 16 * scale, y: y), withAttributes: labelAttrs(.tertiaryLabelColor))
            }
            let label = copyLabel
            let attrs = labelAttrs(copyState == .idle ? .tertiaryLabelColor : .secondaryLabelColor)
            let size = (label as NSString).size(withAttributes: attrs)
            if copyState != .idle {
                NSColor.labelColor.withAlphaComponent(copyState == .hover ? 0.07 : 0.05).setFill()
                NSBezierPath(roundedRect: copyHitRect(inFrame: frameRect), xRadius: 5 * scale, yRadius: 5 * scale).fill()
            }
            (label as NSString).draw(at: NSPoint(x: rect.maxX - 16 * scale - size.width, y: y), withAttributes: attrs)
        case .quote:
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: 3 * scale, height: rect.height), xRadius: 1.5 * scale, yRadius: 1.5 * scale).fill()
        case .rule:
            color.setFill()
            NSRect(x: rect.minX, y: rect.midY.rounded(), width: rect.width, height: 1).fill()
        }
    }
}

/// 16 pt task box: accent fill + white check, or page fill with a gray-3 stroke.
final class CheckboxCell: NSTextAttachmentCell {
    private let checked: Bool
    private let side: CGFloat
    private let stroke: NSColor

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
            stroke.setStroke()
            path.stroke()
        }
    }
}

/// Full-measure image stand-in (board 08b): shown until the file decodes, and kept
/// with an explanation when it can't (outside the granted folder, or missing).
final class ImagePlaceholderCell: NSTextAttachmentCell {
    enum State { case loading, blocked, missing }
    var loadState: State = .loading
    private let name: String
    private let fill: NSColor
    private let stroke: NSColor
    private let scale: CGFloat

    init(name: String, fill: NSColor, stroke: NSColor, scale: CGFloat) {
        self.name = name
        self.fill = fill
        self.stroke = stroke
        self.scale = scale
        super.init(textCell: "")
    }
    required init(coder: NSCoder) { fatalError("not coded") }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        NSRect(x: 0, y: 0, width: max(120, lineFrag.width - position.x), height: 220 * scale)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        fill.setFill()
        NSBezierPath(roundedRect: cellFrame, xRadius: 8 * scale, yRadius: 8 * scale).fill()

        let app = Bundle.main.displayName
        let title: String
        var subtitle: String?
        var button: String?
        switch loadState {
        case .loading: title = name
        case .missing:
            title = "\(app) can\u{2019}t find \(name)"
        case .blocked:
            title = "\(app) can\u{2019}t show \(name)"
            subtitle = "It\u{2019}s outside this file\u{2019}s folder"
            button = "Allow Access\u{2026}"
        }
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.lineBreakMode = .byTruncatingMiddle
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13 * scale, weight: .semibold),
            .foregroundColor: loadState == .loading ? NSColor.tertiaryLabelColor : NSColor.labelColor,
            .paragraphStyle: centered]
        let subtitleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12 * scale), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: centered]
        let buttonAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12 * scale), .foregroundColor: NSColor.labelColor]

        let gap = 10 * scale, icon = 28 * scale, line = 16 * scale, buttonHeight = 26 * scale
        let height = icon + gap + line + (subtitle == nil ? 0 : gap + line) + (button == nil ? 0 : gap + buttonHeight)
        let flipped = controlView?.isFlipped ?? true
        var y = cellFrame.midY - height / 2 // running top edge, in flipped terms
        func frame(_ width: CGFloat, _ h: CGFloat) -> NSRect {
            let top = flipped ? y : cellFrame.maxY - (y - cellFrame.minY) - h
            return NSRect(x: cellFrame.midX - width / 2, y: top, width: width, height: h)
        }
        let textWidth = cellFrame.width - 48 * scale

        let symbol = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: icon * 0.8, weight: .regular).applying(.init(paletteColors: [.secondaryLabelColor])))
        if let symbol {
            let size = symbol.size
            symbol.draw(in: frame(size.width, size.height).offsetBy(dx: 0, dy: (icon - size.height) / 2 * (flipped ? 1 : -1)),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        y += icon + gap
        (title as NSString).draw(in: frame(textWidth, line), withAttributes: titleAttrs)
        y += line
        if let subtitle {
            y += gap
            (subtitle as NSString).draw(in: frame(textWidth, line), withAttributes: subtitleAttrs)
            y += line
        }
        if let button {
            y += gap
            let label = button as NSString
            let size = label.size(withAttributes: buttonAttrs)
            let rect = frame(size.width + 24 * scale, buttonHeight)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7 * scale, yRadius: 7 * scale)
            NSColor.textBackgroundColor.setFill()
            path.fill()
            stroke.setStroke()
            path.lineWidth = 1
            path.stroke()
            label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: buttonAttrs)
        }
    }
}
