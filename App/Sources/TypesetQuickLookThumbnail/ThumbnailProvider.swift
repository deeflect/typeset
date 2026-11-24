import AppKit
import QuickLookThumbnailing
import TypesetCore
import TypesetRendering

/// Quick Look thumbnail provider: renders the top of a Markdown/MDX document
/// onto a crisp light-paper card using the shared `TypesetRendering` engine.
final class ThumbnailProvider: QLThumbnailProvider {
    nonisolated static let readLimit = 32 * 1024

    private final class CompletionBox: @unchecked Sendable {
        let call: (QLThumbnailReply?, Error?) -> Void
        init(_ call: @escaping (QLThumbnailReply?, Error?) -> Void) { self.call = call }
    }

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let fileURL = request.fileURL
        let maxSize = request.maximumSize
        let minSize = request.minimumSize
        let scale = max(1, request.scale)
        let completion = CompletionBox(handler)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let source = try Self.readThumbnailSource(fileURL)
                let mdx = MarkdownParser.isMDX(fileURL)
                let parsed = MarkdownParser.parseDocumentResult(source, mdx: mdx)
                let contextSize = Self.thumbnailContextSize(maximumSize: maxSize, minimumSize: minSize)
                DispatchQueue.main.async {
                    let theme = Theme(colorScheme: .light, scale: 1)
                    let doc = NativeMarkdownDocument.build(
                        source: source,
                        blocks: parsed.blocks,
                        document: parsed.document,
                        theme: theme,
                        documentURL: fileURL,
                        metadataExpanded: false
                    )
                    let attributed = doc.materializedAttributedString()
                    guard let image = Self.renderThumbnailImage(
                        attributed: attributed,
                        size: contextSize,
                        scale: scale
                    ) else {
                        completion.call(nil, CocoaError(.fileReadCorruptFile))
                        return
                    }
                    let reply = QLThumbnailReply(contextSize: contextSize) { context in
                        context.draw(image, in: CGRect(origin: .zero, size: contextSize))
                        return true
                    }
                    completion.call(reply, nil)
                }
            } catch {
                completion.call(nil, error)
            }
        }
    }

    nonisolated static func thumbnailContextSize(maximumSize: CGSize, minimumSize: CGSize) -> CGSize {
        let ratio: CGFloat = 1.32 // portrait document card
        let width = min(maximumSize.width, maximumSize.height / ratio)
        let height = width * ratio
        return CGSize(
            width: max(minimumSize.width, floor(width)),
            height: max(minimumSize.height, floor(height))
        )
    }

    nonisolated static func readThumbnailSource(_ url: URL, limit: Int = readLimit) throws -> String {
        let handle = try FileHandle(forReadingFrom: url.resolvingSymlinksInPath())
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(limit + 4)
        while data.count < limit + 4 {
            guard let chunk = try handle.read(upToCount: limit + 4 - data.count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        let bytes = data.dropFirst(data.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0)
        guard bytes.count > limit else {
            guard let text = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            return text
        }
        let head = bytes.prefix(limit)
        if let newline = head.lastIndex(of: UInt8(ascii: "\n")) {
            let cut = head[..<newline]
            guard String(validating: cut, as: UTF8.self) != nil else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            return String(decoding: cut, as: UTF8.self)
        }
        // Trim up to 3 trailing continuation/lead bytes of an incomplete scalar at `limit`.
        for trim in 0..<min(4, head.count) {
            let slice = head.dropLast(trim)
            if String(validating: slice, as: UTF8.self) != nil {
                return String(decoding: slice, as: UTF8.self)
            }
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    @MainActor
    static func renderThumbnail(
        source: String,
        url: URL?,
        maximumSize: CGSize,
        minimumSize: CGSize = CGSize(width: 32, height: 32),
        scale: CGFloat = 2
    ) -> CGImage? {
        let parsed = MarkdownParser.parseDocument(source, mdx: MarkdownParser.isMDX(url))
        let doc = NativeMarkdownDocument.build(
            source: source,
            blocks: parsed.blocks,
            document: parsed.document,
            theme: Theme(colorScheme: .light, scale: 1),
            documentURL: url,
            metadataExpanded: false
        )
        let size = thumbnailContextSize(maximumSize: maximumSize, minimumSize: minimumSize)
        return renderThumbnailImage(attributed: doc.materializedAttributedString(), size: size, scale: scale)
    }

    @MainActor
    static func renderThumbnailImage(
        attributed: NSAttributedString,
        size: CGSize,
        scale: CGFloat = 2
    ) -> CGImage? {
        let pixelWidth = max(1, Int(ceil(size.width * scale)))
        let pixelHeight = max(1, Int(ceil(size.height * scale)))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        let virtualWidth: CGFloat = 520
        let drawScale = size.width / virtualWidth
        let virtualHeight = size.height / max(0.01, drawScale)
        let inset: CGFloat = 28

        cg.setFillColor(NSColor.white.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        cg.saveGState()
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: drawScale, y: -drawScale)

        let nsContext = NSGraphicsContext(cgContext: cg, flipped: true)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = nsContext
        defer {
            NSGraphicsContext.current = previous
            cg.restoreGState()
        }

        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: virtualWidth - inset * 2, height: virtualHeight))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)

        let visibleRect = NSRect(x: 0, y: 0, width: virtualWidth - inset * 2, height: max(1, virtualHeight - inset))
        let glyphRange = layout.glyphRange(forBoundingRect: visibleRect, in: container)
        let origin = NSPoint(x: inset, y: inset)
        layout.drawBackground(forGlyphRange: glyphRange, at: origin)
        layout.drawGlyphs(forGlyphRange: glyphRange, at: origin)
        nsContext.flushGraphics()

        return cg.makeImage()
    }
}
