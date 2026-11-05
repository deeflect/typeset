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
        /// Drawn state that isn't in the text: task checks, code-card language.
        let marks: [String]
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
                let p = writer.style(writer.bodyFont, lineHeight: theme.bodyLineHeight, after: metadataExpanded ? 4 : 16)
                writer.append(metadataExpanded ? "Metadata ▾" : "Metadata ▸", font: writer.bodyFont, color: writer.secondary, extras: [.marcoMetadata: true])
                writer.endParagraph(from: start, style: p)
                if metadataExpanded, !metadata.isEmpty {
                    let body = writer.output.length
                    writer.append(metadata, font: writer.bodyFont, color: writer.secondary)
                    writer.endParagraph(from: body, style: writer.style(writer.bodyFont, lineHeight: theme.bodyLineHeight))
                }
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
            return a.id == b.id && a.renderedText == b.renderedText && a.links == b.links && a.images == b.images && a.marks == b.marks
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
    /// List and nested-block indent step: 16 pt box + 10 pt gap.
    let indentStep: CGFloat = 26

    mutating func record(block: Block, sourceLine: Int, start: Int) {
        let range = NSRange(location: start, length: output.length - start)
        var links: [String] = []
        output.enumerateAttribute(.link, in: range) { value, part, _ in
            if let url = value as? URL { links.append("\(part.location - start):\(part.length):\(url.absoluteString)") }
        }
        let imageValues = images.filter { NSLocationInRange($0.range.location, range) }.map { "\($0.range.location - start):\($0.alt):\($0.url?.absoluteString ?? "")" }
        let marks = checkboxes.filter { NSLocationInRange($0.range.location, range) }.map { $0.checked ? "x" : "o" }
            + codeRanges.filter { NSLocationInRange($0.range.location, range) }.map { "code:\($0.language ?? "")" }
        ranges.append(.init(id: block.id, sourceLine: sourceLine, range: range, renderedText: output.attributedSubstring(from: range).string, links: links, images: imageValues, marks: marks))
    }

    mutating func append(_ text: String, font: NSFont, color: NSColor = .labelColor, paragraph: NSParagraphStyle? = nil, extras: [NSAttributedString.Key: Any] = [:]) {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let paragraph { attrs[.paragraphStyle] = paragraph }
        attrs.merge(extras) { _, new in new }
        output.append(NSAttributedString(string: text, attributes: attrs))
    }

    /// CSS-style line height: the extra over the font's natural height goes below each line,
    /// so `after` plus that extra reproduces the board's block gap.
    func style(_ font: NSFont, lineHeight: CGFloat, before: CGFloat = 0, after: CGFloat = 16, indent: CGFloat = 0, head: CGFloat? = nil) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = max(0, theme.scaled(lineHeight) - ceil(font.ascender - font.descender + font.leading))
        p.paragraphSpacingBefore = theme.scaled(before)
        p.paragraphSpacing = theme.scaled(after)
        p.firstLineHeadIndent = theme.scaled(indent)
        p.headIndent = theme.scaled(head ?? indent)
        return p
    }

    /// Ends the paragraph begun at `start`. A paragraph that continues a list marker keeps the marker's style.
    mutating func endParagraph(from start: Int, style: NSParagraphStyle, font: NSFont? = nil) {
        append("\n", font: font ?? bodyFont)
        let range = NSRange(location: start, length: output.length - start)
        if start > 0, output.mutableString.character(at: start - 1) != 10,
           let marker = output.attribute(.paragraphStyle, at: start - 1, effectiveRange: nil) {
            output.addAttribute(.paragraphStyle, value: marker, range: range)
        } else {
            output.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

    mutating func updateStyles(in range: NSRange, _ change: (NSMutableParagraphStyle) -> Void) {
        var runs: [(NSRange, NSParagraphStyle?)] = []
        output.enumerateAttribute(.paragraphStyle, in: range) { value, run, _ in runs.append((run, value as? NSParagraphStyle)) }
        for (run, value) in runs {
            let p = (value?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            change(p)
            output.addAttribute(.paragraphStyle, value: p, range: run)
        }
    }

    mutating func setSpacingAfterLastParagraph(in range: NSRange, _ value: CGFloat) {
        guard range.length > 0 else { return }
        let last = output.mutableString.paragraphRange(for: NSRange(location: NSMaxRange(range) - 1, length: 0))
        updateStyles(in: NSIntersectionRange(last, range)) { $0.paragraphSpacing = value }
    }

    /// Steps body-colored text back to secondary (quotes, finished tasks); links keep the accent.
    mutating func dim(_ range: NSRange) {
        var runs: [NSRange] = []
        output.enumerateAttribute(.foregroundColor, in: range) { value, run, _ in
            if (value as? NSColor) == .labelColor { runs.append(run) }
        }
        for run in runs { output.addAttribute(.foregroundColor, value: secondary, range: run) }
    }

    mutating func renderBlock(_ node: any Markup, blockStartLine: Int, depth: Int) {
        let indent = CGFloat(depth) * indentStep
        switch node {
        case let heading as Heading:
            let level = min(max(heading.level, 1), 6)
            // size, line height, space above, space below, tracking (em)
            let specs: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (32, 38, 0, 20, -0.02), (22, 28, 16, 16, -0.01), (18, 24, 8, 16, 0),
                (16, 24, 8, 12, 0), (14, 20, 8, 12, 0), (13, 18, 8, 12, 0)]
            let (size, lineHeight, before, after, tracking) = specs[level - 1]
            let font = NSFont.systemFont(ofSize: size * theme.scale, weight: .semibold)
            let start = output.length
            renderInline(heading, font: font, color: level < 5 ? .labelColor : (level == 5 ? secondary : .tertiaryLabelColor))
            if tracking != 0, output.length > start {
                output.addAttribute(.kern, value: size * theme.scale * tracking, range: NSRange(location: start, length: output.length - start))
            }
            endParagraph(from: start, style: style(font, lineHeight: lineHeight, before: before, after: after, indent: indent), font: font)
        case let code as CodeBlock:
            let mono = NSFont.monospacedSystemFont(ofSize: 13.5 * theme.scale, weight: .regular)
            let block = MarcoTextBlock(.code(language: code.language), color: NSColor(theme.codeCardFill), scale: theme.scale)
            block.setWidth(theme.scaled(indent), type: .absoluteValueType, for: .margin, edge: .minX)
            let p = style(mono, lineHeight: 21, after: 0)
            p.textBlocks = [block]
            let text = code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code
            let start = output.length
            append(text, font: mono, paragraph: p, extras: [.marcoCopy: text])
            codeRanges.append(.init(range: NSRange(location: start, length: output.length - start), code: text, language: code.language))
            append("\n", font: mono, paragraph: p)
        case is OrderedList, is UnorderedList:
            let ordered = node as? OrderedList
            let listStart = output.length
            for (index, child) in node.children.enumerated() {
                guard let item = child as? ListItem else { continue }
                let p = style(bodyFont, lineHeight: theme.bodyLineHeight, after: 6, indent: indent, head: indent + indentStep)
                p.tabStops = [NSTextTab(textAlignment: .left, location: theme.scaled(indent + indentStep))]
                let start = output.length
                if let box = item.checkbox {
                    let attachment = NSTextAttachment()
                    attachment.attachmentCell = CheckboxCell(checked: box == .checked, side: theme.scaled(16), stroke: NSColor(theme.checkboxStroke))
                    append("\u{FFFC}", font: bodyFont, paragraph: p, extras: [.attachment: attachment])
                    append("\t", font: bodyFont, paragraph: p)
                    if let line = item.range?.lowerBound.line {
                        checkboxes.append(.init(range: NSRange(location: start, length: output.length - start), blockStartLine: blockStartLine, lineOffset: line - 1 - blockStartLine, checked: box == .checked))
                    }
                } else {
                    append(ordered.map { "\(Int($0.startIndex) + index).\t" } ?? "\u{2022}\t", font: bodyFont, color: secondary, paragraph: p)
                }
                let contentStart = output.length
                for content in item.children {
                    renderBlock(content, blockStartLine: blockStartLine, depth: depth + 1)
                }
                if item.checkbox == .checked { dim(NSRange(location: contentStart, length: output.length - contentStart)) }
            }
            if depth == 0 { setSpacingAfterLastParagraph(in: NSRange(location: listStart, length: output.length - listStart), theme.scaled(16)) }
        case let table as Markdown.Table:
            renderTable(table)
        case let quote as BlockQuote:
            let start = output.length
            for child in quote.children {
                renderBlock(child, blockStartLine: blockStartLine, depth: depth)
            }
            let range = NSRange(location: start, length: output.length - start)
            let block = MarcoTextBlock(.quote, color: NSColor(theme.quoteBar), scale: theme.scale)
            block.setWidth(theme.scaled(indent), type: .absoluteValueType, for: .margin, edge: .minX)
            updateStyles(in: range) { $0.textBlocks = [block] + $0.textBlocks }
            setSpacingAfterLastParagraph(in: range, 0)
            dim(range)
        case let html as HTMLBlock:
            let mono = NSFont.monospacedSystemFont(ofSize: 12 * theme.scale, weight: .regular)
            let start = output.length
            append(html.rawHTML.hasSuffix("\n") ? String(html.rawHTML.dropLast()) : html.rawHTML, font: mono, color: secondary)
            endParagraph(from: start, style: style(mono, lineHeight: 18, indent: indent), font: mono)
        case is ThematicBreak:
            let p = style(bodyFont, lineHeight: 9, after: 0)
            p.textBlocks = [MarcoTextBlock(.rule, color: NSColor(theme.tableStroke), scale: theme.scale)]
            append("\u{00A0}\n", font: bodyFont, paragraph: p)
        default:
            let start = output.length
            renderInline(node, font: bodyFont)
            endParagraph(from: start, style: style(bodyFont, lineHeight: theme.bodyLineHeight, indent: indent))
        }
    }

    mutating func renderTable(_ table: Markdown.Table) {
        let rows: [any Markup] = [table.head] + Array(table.body.rows)
        let columns = max(1, table.maxColumnCount)
        // Fixed layout keeps 10k-row tables fast; column shares come from content length instead.
        var weights = Array(repeating: 4.0, count: columns)
        for row in rows.prefix(200) {
            for (column, cell) in row.children.enumerated() where column < columns {
                weights[column] = max(weights[column], min(40, Double((cell as? Markdown.Table.Cell)?.plainText.count ?? 0)))
            }
        }
        let total = weights.reduce(0, +)
        let headFont = NSFont.systemFont(ofSize: 14 * theme.scale, weight: .semibold)
        let cellFont = NSFont.systemFont(ofSize: 14 * theme.scale)
        var native = NSTextTable()
        for (rowIndex, row) in rows.enumerated() {
            if rowIndex.isMultiple(of: 200) {
                native = NSTextTable()
                native.numberOfColumns = columns
                native.layoutAlgorithm = .fixedLayoutAlgorithm
                native.setContentWidth(100, type: .percentageValueType)
            }
            let font = rowIndex == 0 ? headFont : cellFont
            for (column, cell) in row.children.enumerated() {
                let block = NSTextTableBlock(table: native, startingRow: rowIndex % 200, rowSpan: 1, startingColumn: column, columnSpan: 1)
                if column < columns { block.setValue(CGFloat(weights[column] / total * 100), type: .percentageValueType, for: .width) }
                block.setWidth(theme.scaled(8), type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(theme.scaled(8), type: .absoluteValueType, for: .padding, edge: .maxY)
                block.setWidth(theme.scaled(12), type: .absoluteValueType, for: .padding, edge: .maxX)
                block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                block.setBorderColor(NSColor(rowIndex == 0 ? theme.tableHeaderRule : theme.tableStroke), for: .maxY)
                let p = style(font, lineHeight: 20, after: 0)
                p.textBlocks = [block]
                if column < table.columnAlignments.count {
                    switch table.columnAlignments[column] {
                    case .some(.center): p.alignment = .center
                    case .some(.right): p.alignment = .right
                    default: p.alignment = .left
                    }
                }
                let cellStart = output.length
                renderInline(cell, font: font)
                if output.length == cellStart { append(" ", font: font) }
                output.addAttribute(.paragraphStyle, value: p, range: NSRange(location: cellStart, length: output.length - cellStart))
                append("\n", font: font, paragraph: p)
            }
        }
        // Spacer paragraph: the block gap after the table.
        let spacer = NSMutableParagraphStyle()
        spacer.minimumLineHeight = theme.scaled(16)
        spacer.maximumLineHeight = theme.scaled(16)
        append("\n", font: .systemFont(ofSize: 1), paragraph: spacer)
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
            let url = resolvedURL(image.source)
            let start = output.length
            let attachment = NSTextAttachment()
            attachment.attachmentCell = ImagePlaceholderCell(
                name: url?.lastPathComponent ?? (alt.isEmpty ? "Image" : alt),
                fill: NSColor(theme.codeCardFill), stroke: NSColor(theme.hairline), scale: theme.scale)
            var extras: [NSAttributedString.Key: Any] = [.attachment: attachment]
            if let link { extras[.link] = link }
            append("\u{FFFC}", font: font, color: secondary, extras: extras)
            images.append(.init(range: NSRange(location: start, length: output.length - start), url: url, alt: alt))
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
