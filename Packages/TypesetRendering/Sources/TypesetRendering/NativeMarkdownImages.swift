import AppKit
import ImageIO

/// URL-backed, local-only thumbnails shared by the reader and rich export.
enum NativeMarkdownImages {
    struct Decoded: @unchecked Sendable { let image: NSImage?; let png: Data? }
    private final class Cached: NSObject { let image: NSImage; let png: Data?; init(image: NSImage, png: Data?) { self.image = image; self.png = png } }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        func stop() { lock.lock(); stopped = true; lock.unlock() }
    }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Cached> = {
        let cache = NSCache<NSString, Cached>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    private static let queue = DispatchQueue(label: "com.deeflect.typeset.native-images", qos: .utility)

    static func load(_ url: URL) async -> Decoded {
        guard url.isFileURL else { return Decoded(image: nil, png: nil) }
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: cancellation.isStopped ? Decoded(image: nil, png: nil) : decode(url))
                }
            }
        } onCancel: { cancellation.stop() }
    }

    nonisolated private static func decode(_ url: URL) -> Decoded {
        let value = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = "\(url.path)|\(value?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(value?.fileSize ?? 0)" as NSString
        if let cached = cache.object(forKey: key) { return Decoded(image: cached.image, png: cached.png) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1200,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return Decoded(image: nil, png: nil) }
        let result = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        cache.setObject(Cached(image: result, png: png), forKey: key, cost: cg.bytesPerRow * cg.height + (png?.count ?? 0))
        return Decoded(image: result, png: png)
    }

    @MainActor static func attachment(for decoded: Decoded, maxWidth: CGFloat = 600, isDark: Bool) -> NSTextAttachment {
        guard let image = decoded.image else { return NSTextAttachment() }
        let display = image.copy() as! NSImage
        if display.size.width > maxWidth {
            display.size = NSSize(width: maxWidth, height: maxWidth * display.size.height / display.size.width)
        }
        let attachment = NSTextAttachment()
        if let png = decoded.png {
            let wrapper = FileWrapper(regularFileWithContents: png)
            wrapper.preferredFilename = "image.png"
            attachment.fileWrapper = wrapper
        }
        let cell = LoadedImageCell(imageCell: display)
        cell.hairline = NSColor(Theme(colorScheme: isDark ? .dark : .light, scale: 1).hairline)
        attachment.attachmentCell = cell
        return attachment
    }
}

public extension NativeMarkdownDocument {
    /// Load local images, diagrams, and math for PDF/RTF export without changing character offsets.
    @MainActor func withLoadedLocalImages() async -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: materializedAttributedString())
        for image in images {
            guard let url = image.url, url.isFileURL else { continue }
            let decoded = await NativeMarkdownImages.load(url)
            guard decoded.image != nil else { continue }
            result.addAttribute(.attachment, value: NativeMarkdownImages.attachment(for: decoded, isDark: isDark), range: image.range)
        }
        for diagram in diagrams {
            let rendered = await DiagramRenderer.shared.render(diagram.source, kind: diagram.kind, isDark: isDark, fontSize: diagram.fontSize)
            let existing = result.attribute(.attachment, at: diagram.range.location, effectiveRange: nil) as? NSTextAttachment
            if let attachment = diagram.attachment(for: rendered, maxWidth: 600, existing: existing, isDark: isDark) {
                result.addAttribute(.attachment, value: attachment, range: diagram.range)
            }
        }
        for code in codeRanges {
            guard let highlighted = await CodeHighlighter.shared.highlightedNative(code: code.code, language: code.language, isDark: isDark),
                  highlighted.length == code.range.length else { continue }
            highlighted.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: highlighted.length)) { value, range, _ in
                if let value { result.addAttribute(.foregroundColor, value: value, range: NSRange(location: code.range.location + range.location, length: range.length)) }
            }
        }
        return result
    }
}
