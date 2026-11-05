import AppKit
import MarcoCore
import Markdown
import SwiftUI

/// Rendered, selectable text and the source identities needed by the reader.
public struct NativeMarkdownDocument: @unchecked Sendable {
    public struct BlockRange {
        public let id: String
        public let sourceLine: Int
        public let range: NSRange
        let renderedText: String
        let links: [String]
        let images: [String]
    }
    public struct Checkbox {
        public let range: NSRange
        public let blockStartLine: Int
        public let lineOffset: Int
        public let checked: Bool
    }
    public struct ImageReference {
        public let range: NSRange
        public let url: URL?
        public let alt: String
    }
    public struct CodeRange {
        public let range: NSRange
        public let code: String
        public let language: String?
    }

    public let attributedString: NSAttributedString
    public let blockRanges: [BlockRange]
    public let checkboxes: [Checkbox]
    public let images: [ImageReference]
    public let codeRanges: [CodeRange]
    let isDark: Bool
    let scale: CGFloat
    let documentURL: URL?

    /// Parse once as a complete document so reference definitions resolve in every block.
    public static func build(source: String, blocks: [Block], theme: Theme, documentURL: URL?, metadataExpanded: Bool = true) -> Self {
        make(source: source, blocks: blocks, theme: theme, documentURL: documentURL, metadataExpanded: metadataExpanded, cancellable: false)!
    }

    /// Use from a detached reload task; cancelled work never returns a partial document.
    public static func buildCancellable(source: String, blocks: [Block], theme: Theme, documentURL: URL?, metadataExpanded: Bool = true) throws -> Self {
        guard let result = make(source: source, blocks: blocks, theme: theme, documentURL: documentURL, metadataExpanded: metadataExpanded, cancellable: true) else {
            throw CancellationError()
        }
        return result
    }

    private static func make(source: String, blocks: [Block], theme: Theme, documentURL: URL?, metadataExpanded: Bool, cancellable: Bool) -> Self? {
        if cancellable && Task<Never, Never>.isCancelled { return nil }
        var writer = Writer(theme: theme, documentURL: documentURL)
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lineOffset = MarkdownParser.bodyLineOffset(in: normalized)
        let body = normalized.split(separator: "\n", omittingEmptySubsequences: false).dropFirst(lineOffset).joined(separator: "\n")
        if lineOffset > 0 {
            let metadata = normalized.split(separator: "\n", omittingEmptySubsequences: false).prefix(lineOffset).dropFirst().dropLast().joined(separator: "\n")
            if let block = blocks.first, block.kind == .frontmatter {
                let start = writer.output.length
                writer.append(metadataExpanded ? "Metadata ▾" : "Metadata ▸", font: writer.bodyFont, color: writer.secondary, extras: [.marcoMetadata: true])
                if metadataExpanded, !metadata.isEmpty {
                    writer.endBlock()
                    writer.append(metadata, font: writer.bodyFont, color: writer.secondary)
                }
                writer.endBlock()
                writer.record(block: block, sourceLine: -1, start: start)
            }
        }
        let document = Document(parsing: body)
        if cancellable && Task<Never, Never>.isCancelled { return nil }
        let byLine = Dictionary(uniqueKeysWithValues: blocks.filter { $0.startLine >= 0 }.map { ($0.startLine, $0) })
        for (index, child) in document.children.enumerated() {
            if cancellable && index.isMultiple(of: 32) && Task<Never, Never>.isCancelled { return nil }
            let startLine = (child.range?.lowerBound.line ?? 1) - 1
            let block = byLine[startLine]
            let start = writer.output.length
            writer.renderBlock(child, blockStartLine: startLine, depth: 0)
            if let block {
                writer.record(block: block, sourceLine: startLine, start: start)
            }
        }
        if cancellable && Task<Never, Never>.isCancelled { return nil }
        return Self(attributedString: writer.output.copy() as! NSAttributedString, blockRanges: writer.ranges, checkboxes: writer.checkboxes, images: writer.images, codeRanges: writer.codeRanges, isDark: theme.colorScheme == .dark, scale: theme.scale, documentURL: documentURL)
    }

    /// One changed span keeps TextKit's existing laid-out viewport intact on reload.
    func replacementRanges(from old: Self) -> (old: NSRange, new: NSRange) {
        guard isDark == old.isDark, scale == old.scale, documentURL == old.documentURL else {
            return (NSRange(location: 0, length: old.attributedString.length), NSRange(location: 0, length: attributedString.length))
        }
        func matches(_ oldIndex: Int, _ newIndex: Int) -> Bool {
            let a = old.blockRanges[oldIndex], b = blockRanges[newIndex]
            return a.id == b.id && a.renderedText == b.renderedText && a.links == b.links && a.images == b.images
        }
        var prefix = 0
        while prefix < min(old.blockRanges.count, blockRanges.count), matches(prefix, prefix) { prefix += 1 }
        var suffix = 0
        while suffix < min(old.blockRanges.count, blockRanges.count) - prefix,
              matches(old.blockRanges.count - suffix - 1, blockRanges.count - suffix - 1) { suffix += 1 }
        let oldStart = prefix < old.blockRanges.count ? old.blockRanges[prefix].range.location : old.attributedString.length
        let newStart = prefix < blockRanges.count ? blockRanges[prefix].range.location : attributedString.length
        let oldEnd = suffix > 0 ? old.blockRanges[old.blockRanges.count - suffix].range.location : old.attributedString.length
        let newEnd = suffix > 0 ? blockRanges[blockRanges.count - suffix].range.location : attributedString.length
        return (NSRange(location: oldStart, length: max(0, oldEnd - oldStart)), NSRange(location: newStart, length: max(0, newEnd - newStart)))
    }

    func remappedSelection(_ selection: NSRange, from old: Self) -> NSRange? {
        guard let startBlock = old.block(at: selection.location),
              let endBlock = old.block(at: NSMaxRange(selection)),
              let newStart = blockRanges.first(where: { $0.id == startBlock.id })?.range,
              let newEnd = blockRanges.first(where: { $0.id == endBlock.id })?.range else { return nil }
        let start = newStart.location + min(max(0, selection.location - startBlock.range.location), newStart.length)
        let end = newEnd.location + min(max(0, NSMaxRange(selection) - endBlock.range.location), newEnd.length)
        return NSRange(location: start, length: max(0, end - start))
    }

    func block(at character: Int) -> BlockRange? {
        var low = 0, high = blockRanges.count
        while low < high {
            let mid = (low + high) / 2
            if blockRanges[mid].range.location <= character { low = mid + 1 }
            else { high = mid }
        }
        return low == 0 ? nil : blockRanges[low - 1]
    }
}

private struct Writer {
    let theme: Theme
    let documentURL: URL?
    let output = NSMutableAttributedString(string: "")
    var ranges: [NativeMarkdownDocument.BlockRange] = []
    var checkboxes: [NativeMarkdownDocument.Checkbox] = []
    var images: [NativeMarkdownDocument.ImageReference] = []
    var codeRanges: [NativeMarkdownDocument.CodeRange] = []
    var bodyFont: NSFont { .systemFont(ofSize: theme.bodySize * theme.scale) }
    var secondary: NSColor { .secondaryLabelColor }

    mutating func record(block: Block, sourceLine: Int, start: Int) {
        let range = NSRange(location: start, length: output.length - start)
        var links: [String] = []
        output.enumerateAttribute(.link, in: range) { value, part, _ in
            if let url = value as? URL { links.append("\(part.location - start):\(part.length):\(url.absoluteString)") }
        }
        let imageValues = images.filter { NSLocationInRange($0.range.location, range) }.map { "\($0.range.location - start):\($0.alt):\($0.url?.absoluteString ?? "")" }
        ranges.append(.init(id: block.id, sourceLine: sourceLine, range: range, renderedText: output.attributedSubstring(from: range).string, links: links, images: imageValues))
    }

    mutating func append(_ text: String, font: NSFont, color: NSColor = .labelColor, paragraph: NSParagraphStyle? = nil, extras: [NSAttributedString.Key: Any] = [:]) {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let paragraph { attrs[.paragraphStyle] = paragraph }
        attrs.merge(extras) { _, new in new }
        output.append(NSAttributedString(string: text, attributes: attrs))
    }

    mutating func endBlock() { append("\n", font: bodyFont) }

    mutating func renderBlock(_ node: any Markup, blockStartLine: Int, depth: Int) {
        switch node {
        case let heading as Heading:
            let sizes: [CGFloat] = [30, 23, 18.5, 15.5, 13.5, 12]
            let size = sizes[min(max(heading.level, 1), 6) - 1] * theme.scale
            let start = output.length
            renderInline(heading, font: .boldSystemFont(ofSize: size))
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = theme.scaled(heading.level == 1 ? 8 : 20)
            p.paragraphSpacing = theme.scaled(heading.level == 1 ? 12 : 8)
            if output.length > start { output.addAttribute(.paragraphStyle, value: p, range: NSRange(location: start, length: output.length - start)) }
            endBlock()
        case let code as CodeBlock:
            let p = NSMutableParagraphStyle()
            p.paragraphSpacing = theme.scaled(12)
            p.headIndent = theme.scaled(12)
            p.firstLineHeadIndent = p.headIndent
            let text = code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code
            let start = output.length
            append(text, font: .monospacedSystemFont(ofSize: 13 * theme.scale, weight: .regular), paragraph: p, extras: [.marcoCopy: text])
            codeRanges.append(.init(range: NSRange(location: start, length: output.length - start), code: text, language: code.language))
            endBlock()
        case is OrderedList, is UnorderedList:
            let ordered = node as? OrderedList
            for (index, child) in node.children.enumerated() {
                guard let item = child as? ListItem else { continue }
                let marker = ordered.map { "\(Int($0.startIndex) + index). " } ?? "• "
                let checked = item.checkbox != nil
                let start = output.length
                let p = NSMutableParagraphStyle()
                p.firstLineHeadIndent = theme.scaled(CGFloat(depth) * 24)
                p.headIndent = p.firstLineHeadIndent + theme.scaled(24)
                p.paragraphSpacing = theme.scaled(4)
                append(checked ? (item.checkbox == .checked ? "☑ " : "☐ ") : marker, font: bodyFont, color: secondary, paragraph: p)
                if checked, let line = item.range?.lowerBound.line {
                    checkboxes.append(.init(range: NSRange(location: start, length: (output.length - start)), blockStartLine: blockStartLine, lineOffset: line - 1 - blockStartLine, checked: item.checkbox == .checked))
                }
                for content in item.children {
                    renderBlock(content, blockStartLine: blockStartLine, depth: depth + 1)
                }
            }
        case let table as Markdown.Table:
            renderTable(table)
        case let quote as BlockQuote:
            for child in quote.children {
                append("│ ", font: bodyFont, color: secondary)
                renderBlock(child, blockStartLine: blockStartLine, depth: depth + 1)
            }
        case let code as InlineCode:
            append(code.code, font: .monospacedSystemFont(ofSize: theme.inlineCodeSize * theme.scale, weight: .regular), extras: [.backgroundColor: NSColor(theme.inlineCodeFill), .marcoCopy: code.code])
        case let html as HTMLBlock:
            append(html.rawHTML, font: .monospacedSystemFont(ofSize: 12 * theme.scale, weight: .regular), color: secondary)
            endBlock()
        case is ThematicBreak:
            append("────────", font: bodyFont, color: secondary)
            endBlock()
        default:
            let start = output.length
            renderInline(node, font: bodyFont)
            if output.length > start {
                let p = NSMutableParagraphStyle()
                p.firstLineHeadIndent = theme.scaled(CGFloat(depth) * 24)
                p.headIndent = p.firstLineHeadIndent
                p.paragraphSpacing = theme.scaled(9)
                p.lineSpacing = theme.bodyLineSpacing
                output.addAttribute(.paragraphStyle, value: p, range: NSRange(location: start, length: output.length - start))
            }
            endBlock()
        }
    }

    mutating func renderTable(_ table: Markdown.Table) {
        let rows: [any Markup] = [table.head] + Array(table.body.rows)
        var native = NSTextTable()
        for (rowIndex, row) in rows.enumerated() {
            if rowIndex.isMultiple(of: 200) {
                native = NSTextTable()
                native.numberOfColumns = table.maxColumnCount
                native.layoutAlgorithm = .fixedLayoutAlgorithm
                native.setContentWidth(100, type: .percentageValueType)
            }
            for (column, cell) in row.children.enumerated() {
                let block = NSTextTableBlock(table: native, startingRow: rowIndex % 200, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setBorderColor(NSColor(theme.tableStroke))
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                if rowIndex == 0 { block.backgroundColor = NSColor(theme.tableHeaderFill) }
                let p = NSMutableParagraphStyle()
                p.textBlocks = [block]
                if column < table.columnAlignments.count {
                    switch table.columnAlignments[column] {
                    case .some(.center): p.alignment = .center
                    case .some(.right): p.alignment = .right
                    default: p.alignment = .left
                    }
                }
                let cellStart = output.length
                renderInline(cell, font: rowIndex == 0 ? .boldSystemFont(ofSize: theme.bodySize * theme.scale) : bodyFont)
                if output.length == cellStart { append(" ", font: bodyFont) }
                output.addAttribute(.paragraphStyle, value: p, range: NSRange(location: cellStart, length: output.length - cellStart))
                append("\n", font: bodyFont, paragraph: p)
            }
        }
        endBlock()
    }

    mutating func renderInline(_ node: any Markup, font: NSFont, color: NSColor = .labelColor, link: URL? = nil) {
        if let text = node as? Markdown.Text { append(text.string, font: font, color: color, extras: link.map { [.link: $0] } ?? [:]); return }
        if let code = node as? InlineCode {
            var extras: [NSAttributedString.Key: Any] = [.backgroundColor: NSColor(theme.inlineCodeFill)]
            if let link { extras[.link] = link }
            else { extras[.marcoCopy] = code.code }
            append(code.code, font: .monospacedSystemFont(ofSize: font.pointSize * 0.94, weight: .regular), color: color, extras: extras)
            return
        }
        if node is SoftBreak { append(" ", font: font, color: color); return }
        if node is LineBreak { append("\n", font: font, color: color); return }
        if let html = node as? InlineHTML { append(html.rawHTML, font: font, color: secondary); return }
        if let image = node as? Markdown.Image {
            let alt = image.children.compactMap { ($0 as? Markdown.Text)?.string }.joined()
            let start = output.length
            let attachment = NSTextAttachment()
            attachment.attachmentCell = NSTextAttachmentCell(imageCell: NSImage(systemSymbolName: "photo", accessibilityDescription: alt.isEmpty ? "Image" : alt)!)
            var extras: [NSAttributedString.Key: Any] = [.attachment: attachment]
            if let link { extras[.link] = link }
            append("\u{FFFC}", font: font, color: secondary, extras: extras)
            images.append(.init(range: NSRange(location: start, length: output.length - start), url: resolvedURL(image.source), alt: alt))
            return
        }
        var childFont = font
        if node is Strong { childFont = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.bold)), size: font.pointSize) ?? font }
        if node is Emphasis { childFont = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic)), size: font.pointSize) ?? font }
        let childLink = (node as? Markdown.Link).flatMap { resolvedURL($0.destination) } ?? link
        let start = output.length
        for child in node.children { renderInline(child, font: childFont, color: childLink == nil ? color : NSColor(theme.linkColor), link: childLink) }
        if node is Strikethrough, output.length > start { output.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: start, length: output.length - start)) }
    }

    func resolvedURL(_ source: String?) -> URL? {
        guard let source, !source.isEmpty else { return nil }
        if let url = URL(string: source), url.scheme != nil { return url }
        guard let documentURL else { return nil }
        guard let resolved = URL(string: source, relativeTo: documentURL)?.absoluteURL else { return nil }
        guard resolved.isFileURL else { return resolved }
        var parts = URLComponents(url: resolved, resolvingAgainstBaseURL: false)
        parts?.percentEncodedPath = URLComponents(url: resolved.standardizedFileURL, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? resolved.path
        return parts?.url
    }
}

extension NSAttributedString.Key {
    static let marcoCopy = NSAttributedString.Key("com.dee.marco.copy")
    static let marcoMetadata = NSAttributedString.Key("com.dee.marco.metadata")
}
