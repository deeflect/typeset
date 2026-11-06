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
    /// Footnote fragment (`fn-<label>`) → id of the block holding its definition.
    public let footnoteBlockIDs: [String: String]
    let isDark: Bool
    let scale: CGFloat
    let documentURL: URL?

    @MainActor public func materializedAttributedString(in range: NSRange? = nil) -> NSAttributedString {
        let range = range ?? NSRange(location: 0, length: attributedString.length)
        let result = NSMutableAttributedString(attributedString: attributedString.attributedSubstring(from: range))
        let theme = Theme(colorScheme: isDark ? .dark : .light, scale: scale)
        for checkbox in checkboxes where NSLocationInRange(checkbox.range.location, range) {
            let attachment = NSTextAttachment()
            attachment.attachmentCell = CheckboxCell(
                checked: checkbox.checked, side: theme.scaled(16), stroke: NSColor(theme.checkboxStroke))
            result.addAttribute(.attachment, value: attachment,
                                range: NSRange(location: checkbox.range.location - range.location, length: 1))
        }
        for image in images where NSLocationInRange(image.range.location, range) {
            let attachment = NSTextAttachment()
            attachment.attachmentCell = ImagePlaceholderCell(
                name: image.url?.lastPathComponent ?? (image.alt.isEmpty ? "Image" : image.alt),
                fill: NSColor(theme.codeCardFill), stroke: NSColor(theme.hairline), scale: scale)
            result.addAttribute(.attachment, value: attachment,
                                range: NSRange(location: image.range.location - range.location, length: image.range.length))
        }
        return result
    }

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
        let document = Document(parsing: MarkdownParser.bodyForParsing(body))
        if cancellable && Task<Never, Never>.isCancelled { return nil }
        let byLine = Dictionary(uniqueKeysWithValues: blocks.filter { $0.startLine >= 0 }.map { ($0.startLine, $0) })
        writer.numberFootnotes(in: document)
        for (index, child) in document.children.enumerated() {
            if cancellable && index.isMultiple(of: 32) && Task<Never, Never>.isCancelled { return nil }
            let startLine = (child.range?.lowerBound.line ?? 1) - 1
            let block = byLine[startLine]
            let start = writer.output.length
            let imageStart = writer.images.count
            let checkboxStart = writer.checkboxes.count
            let codeStart = writer.codeRanges.count
            writer.currentBlockID = block?.id
            writer.openTags = []
            writer.renderBlock(child, blockStartLine: startLine, depth: 0)
            if let block {
                writer.record(block: block, sourceLine: startLine, start: start,
                              imageStart: imageStart, checkboxStart: checkboxStart, codeStart: codeStart)
            }
        }
        if cancellable && Task<Never, Never>.isCancelled { return nil }
        return Self(attributedString: writer.output.copy() as! NSAttributedString, blockRanges: writer.ranges, checkboxes: writer.checkboxes, images: writer.images, codeRanges: writer.codeRanges, footnoteBlockIDs: writer.footnoteBlockIDs, isDark: theme.colorScheme == .dark, scale: theme.scale, documentURL: documentURL)
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
    var currentBlockID: String?
    var footnoteBlockIDs: [String: String] = [:]
    var footnoteNumbers: [String: Int] = [:]
    /// Open inline HTML tags; each styles what rendered since its opener when it closes.
    var openTags: [(name: String, start: Int, link: URL?)] = []
    var bodyFont: NSFont { .systemFont(ofSize: theme.bodySize * theme.scale) }
    var secondary: NSColor { .secondaryLabelColor }
    /// List and nested-block indent step: 16 pt box + 10 pt gap.
    let indentStep: CGFloat = 26

    mutating func record(block: Block, sourceLine: Int, start: Int,
                         imageStart: Int = 0, checkboxStart: Int = 0, codeStart: Int = 0) {
        let range = NSRange(location: start, length: output.length - start)
        var links: [String] = []
        output.enumerateAttribute(.link, in: range) { value, part, _ in
            if let url = value as? URL { links.append("\(part.location - start):\(part.length):\(url.absoluteString)") }
        }
        let imageValues = images[imageStart...].map { "\($0.range.location - start):\($0.alt):\($0.url?.absoluteString ?? "")" }
        let marks = checkboxes[checkboxStart...].map { $0.checked ? "x" : "o" }
            + codeRanges[codeStart...].map { "code:\($0.language ?? "")" }
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
        var lineStart = start
        for index in start..<(output.length - 1) where output.mutableString.character(at: index) == 10 {
            updateStyles(in: NSRange(location: lineStart, length: index - lineStart + 1)) { $0.paragraphSpacing = 0 }
            lineStart = index + 1
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
            var children = Array(quote.children)
            let alert = Self.alert(quote)
            if let alert {
                renderAlertTitle(alert, indent: indent)
                // Drop the marker line; the rest of its paragraph is the body's first paragraph.
                let rest = (children.removeFirst() as? Paragraph).map { Array($0.inlineChildren.dropFirst(2)) } ?? []
                if !rest.isEmpty { renderBlock(Paragraph(rest), blockStartLine: blockStartLine, depth: depth) }
            }
            for child in children {
                renderBlock(child, blockStartLine: blockStartLine, depth: depth)
            }
            let range = NSRange(location: start, length: output.length - start)
            let block = MarcoTextBlock(.quote, color: alert?.tint ?? NSColor(theme.quoteBar), scale: theme.scale)
            block.setWidth(theme.scaled(indent), type: .absoluteValueType, for: .margin, edge: .minX)
            updateStyles(in: range) { $0.textBlocks = [block] + $0.textBlocks }
            setSpacingAfterLastParagraph(in: range, 0)
            if alert == nil { dim(range) }
        case let html as HTMLBlock:
            // Comments are notes for humans (CLAUDE.md); an all-comment block renders nothing.
            let raw = html.rawHTML.replacing(#/<!--[\s\S]*?-->/#, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { break }
            if raw.matches(of: #/<[^>]*>/#).allSatisfy({ Self.tag(String($0.output)).map { Self.inlineTags.union(Self.blockTags).contains($0.name) } ?? false }) {
                renderHTMLBlock(raw, indent: indent)
                break
            }
            let mono = NSFont.monospacedSystemFont(ofSize: 12 * theme.scale, weight: .regular)
            let start = output.length
            append(raw, font: mono, color: secondary)
            endParagraph(from: start, style: style(mono, lineHeight: 18, indent: indent), font: mono)
        case is ThematicBreak:
            let p = style(bodyFont, lineHeight: 9, after: 0)
            p.textBlocks = [MarcoTextBlock(.rule, color: NSColor(theme.tableStroke), scale: theme.scale)]
            append("\u{00A0}\n", font: bodyFont, paragraph: p)
        case let paragraph as Paragraph where Self.footnoteDefinition(in: Array(paragraph.children), at: 0) != nil:
            renderFootnoteDefinitions(paragraph, indent: indent)
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
        if let html = node as? InlineHTML {
            if !renderTag(html.rawHTML, font: font, color: color, link: link) { append(html.rawHTML, font: font, color: secondary) }
            return
        }
        if let image = node as? Markdown.Image {
            appendImage(source: image.source, alt: image.children.compactMap { ($0 as? Markdown.Text)?.string }.joined(), font: font, link: link)
            return
        }
        var childFont = font
        if node is Strong { childFont = font.adding(.bold) }
        if node is Emphasis { childFont = font.adding(.italic) }
        let childLink = (node as? Markdown.Link).flatMap { resolvedURL($0.destination) } ?? link
        let start = output.length
        for child in node.children {
            let childColor = childLink == nil ? color : NSColor(theme.linkColor)
            if let text = (child as? Markdown.Text)?.string, !footnoteNumbers.isEmpty, text.contains("[^") {
                renderFootnoteText(text, font: childFont, color: childColor, link: childLink)
            } else {
                renderInline(child, font: childFont, color: childColor, link: childLink)
            }
        }
        if node is Strikethrough, output.length > start { output.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: start, length: output.length - start)) }
    }

    mutating func appendImage(source: String?, alt: String, font: NSFont, link: URL?) {
        let url = resolvedURL(source)
        let start = output.length
        let attachment = NSTextAttachment()
        var extras: [NSAttributedString.Key: Any] = [.attachment: attachment]
        if let link { extras[.link] = link }
        append("\u{FFFC}", font: font, color: secondary, extras: extras)
        images.append(.init(range: NSRange(location: start, length: output.length - start), url: url, alt: alt))
    }

    mutating func mapFonts(in range: NSRange, _ change: (NSFont) -> NSFont) {
        var runs: [(NSRange, NSFont)] = []
        output.enumerateAttribute(.font, in: range) { value, run, _ in if let font = value as? NSFont { runs.append((run, font)) } }
        for (run, font) in runs { output.addAttribute(.font, value: change(font), range: run) }
    }

    // MARK: GitHub alerts

    struct Alert { let label: String, symbol: String, tint: NSColor }

    /// GitHub's rule: the quote's first line is exactly `[!KIND]`, any case.
    static func alert(_ quote: BlockQuote) -> Alert? {
        guard let paragraph = quote.child(at: 0) as? Paragraph,
              let marker = (paragraph.child(at: 0) as? Markdown.Text)?.string,
              paragraph.childCount == 1 || paragraph.child(at: 1) is SoftBreak || paragraph.child(at: 1) is LineBreak else { return nil }
        switch marker.trimmingCharacters(in: .whitespaces).lowercased() {
        case "[!note]": return Alert(label: "Note", symbol: "info.circle", tint: .systemBlue)
        case "[!tip]": return Alert(label: "Tip", symbol: "lightbulb", tint: .systemGreen)
        case "[!important]": return Alert(label: "Important", symbol: "exclamationmark.bubble", tint: .systemPurple)
        case "[!warning]": return Alert(label: "Warning", symbol: "exclamationmark.triangle", tint: .systemOrange)
        case "[!caution]": return Alert(label: "Caution", symbol: "exclamationmark.octagon", tint: .systemRed)
        default: return nil
        }
    }

    mutating func renderAlertTitle(_ alert: Alert, indent: CGFloat) {
        let font = NSFont.systemFont(ofSize: theme.bodySize * theme.scale, weight: .semibold)
        let start = output.length
        let attachment = NSTextAttachment()
        if let image = NSImage(systemSymbolName: alert.symbol, accessibilityDescription: alert.label)?
            .withSymbolConfiguration(.init(pointSize: font.pointSize * 0.94, weight: .semibold).applying(.init(paletteColors: [alert.tint]))) {
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: (font.capHeight - image.size.height) / 2, width: image.size.width, height: image.size.height)
        }
        append("\u{FFFC}", font: font, color: alert.tint, extras: [.attachment: attachment])
        append(" \(alert.label)", font: font, color: alert.tint)
        endParagraph(from: start, style: style(font, lineHeight: theme.bodyLineHeight, after: 6, indent: indent), font: font)
    }

    // MARK: Footnotes (swift-markdown leaves `[^label]` as text)

    static var footnoteRef: Regex<(Substring, Substring)> { #/\[\^([^\]\s]+)\]/# }

    /// `[^label]: rest` at the start of a paragraph line.
    static func footnoteDefinition(in children: [any Markup], at index: Int) -> (label: String, rest: String)? {
        guard index < children.count, index == 0 || children[index - 1] is SoftBreak || children[index - 1] is LineBreak,
              let text = (children[index] as? Markdown.Text)?.string,
              let match = text.prefixMatch(of: #/\[\^([^\]\s]+)\]:[ \t]*/#) else { return nil }
        return (match.1.lowercased(), String(text[match.range.upperBound...]))
    }

    /// GitHub numbers footnotes by first reference; a reference without a definition stays literal.
    mutating func numberFootnotes(in document: Markdown.Document) {
        var order: [String] = [], defined: Set<String> = []
        func scan(_ node: any Markup) {
            let children = Array(node.children)
            for (index, child) in children.enumerated() {
                guard var text = (child as? Markdown.Text)?.string else { scan(child); continue }
                guard text.contains("[^") else { continue }
                if node is Paragraph, let definition = Self.footnoteDefinition(in: children, at: index) {
                    defined.insert(definition.label)
                    text = definition.rest
                }
                for match in text.matches(of: Self.footnoteRef) where !order.contains(match.1.lowercased()) { order.append(match.1.lowercased()) }
            }
        }
        scan(document)
        for label in order where defined.contains(label) { footnoteNumbers[label] = footnoteNumbers.count + 1 }
    }

    /// Text with `[^label]` references as small raised links to `#fn-label`.
    mutating func renderFootnoteText(_ string: String, font: NSFont, color: NSColor, link: URL?) {
        var last = string.startIndex
        for match in string.matches(of: Self.footnoteRef) {
            let label = match.1.lowercased()
            guard let number = footnoteNumbers[label] else { continue }
            if last < match.range.lowerBound { renderInline(Markdown.Text(String(string[last..<match.range.lowerBound])), font: font, color: color, link: link) }
            var extras: [NSAttributedString.Key: Any] = [.baselineOffset: font.pointSize * 0.36]
            if let url = resolvedURL("#fn-\(label)") { extras[.link] = url }
            append("\(number)", font: .systemFont(ofSize: font.pointSize * 0.72, weight: .medium), color: NSColor(theme.linkColor), extras: extras)
            last = match.range.upperBound
        }
        if last < string.endIndex { renderInline(Markdown.Text(String(string[last...])), font: font, color: color, link: link) }
    }

    /// Definitions stay where they are written (block mapping), small and secondary, one paragraph each.
    mutating func renderFootnoteDefinitions(_ paragraph: Paragraph, indent: CGFloat) {
        let font = NSFont.systemFont(ofSize: 13 * theme.scale)
        let p = style(font, lineHeight: 20, after: 4, indent: indent, head: indent + 22)
        p.tabStops = [NSTextTab(textAlignment: .left, location: theme.scaled(indent + 22))]
        let blockStart = output.length
        var start = output.length
        let children = Array(paragraph.children)
        for (index, child) in children.enumerated() {
            if let definition = Self.footnoteDefinition(in: children, at: index) {
                if output.length > start { endParagraph(from: start, style: p, font: font) }
                start = output.length
                let number = footnoteNumbers[definition.label] ?? footnoteNumbers.count + 1
                footnoteNumbers[definition.label] = number
                if let currentBlockID { footnoteBlockIDs["fn-\(definition.label)"] = currentBlockID }
                append("\(number).\t", font: font, color: .tertiaryLabelColor)
                if (definition.rest.hasPrefix("https://") || definition.rest.hasPrefix("http://")),
                   !definition.rest.contains(where: \.isWhitespace), let url = URL(string: definition.rest) {
                    append(definition.rest, font: font, color: NSColor(theme.linkColor), extras: [.link: url])
                } else {
                    renderFootnoteText(definition.rest, font: font, color: secondary, link: nil)
                }
            } else if child is SoftBreak || child is LineBreak, Self.footnoteDefinition(in: children, at: index + 1) != nil {
                continue
            } else if let text = (child as? Markdown.Text)?.string {
                renderFootnoteText(text, font: font, color: secondary, link: nil)
            } else {
                renderInline(child, font: font, color: secondary)
            }
        }
        endParagraph(from: start, style: p, font: font)
        setSpacingAfterLastParagraph(in: NSRange(location: blockStart, length: output.length - blockStart), theme.scaled(16))
    }

    // MARK: README HTML (a tag stack, not an HTML parser; unknown tags stay raw)

    static let inlineTags: Set<String> = ["b", "strong", "i", "em", "kbd", "sub", "sup", "a", "br", "img"]
    static let blockTags: Set<String> = ["p", "div", "details", "summary"]

    static func tag(_ raw: String) -> (name: String, closing: Bool, attributes: String)? {
        guard let match = raw.wholeMatch(of: #/<(/?)([A-Za-z][A-Za-z0-9]*)(\s[^>]*)?/?>/#) else { return nil }
        return (match.2.lowercased(), !match.1.isEmpty, String(match.3 ?? ""))
    }

    static func attribute(_ name: String, in attributes: String) -> String? {
        for match in attributes.matches(of: #/([A-Za-z-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/#) where match.1.lowercased() == name {
            return String(match.2 ?? match.3 ?? match.4 ?? "")
        }
        return nil
    }

    /// Returns false for tags it doesn't know, which the caller shows raw.
    mutating func renderTag(_ raw: String, font: NSFont, color: NSColor, link: URL?) -> Bool {
        if raw.hasPrefix("<!--") { return true }
        guard let tag = Self.tag(raw), Self.inlineTags.contains(tag.name) else { return false }
        switch tag.name {
        case "br": if !tag.closing { append("\n", font: font, color: color) }
        case "img":
            if !tag.closing { appendImage(source: Self.attribute("src", in: tag.attributes), alt: Self.attribute("alt", in: tag.attributes) ?? "", font: font, link: link) }
        default:
            if !tag.closing { openTags.append((tag.name, output.length, Self.attribute("href", in: tag.attributes).flatMap(resolvedURL))); break }
            guard let index = openTags.lastIndex(where: { $0.name == tag.name }) else { break }
            let open = openTags.remove(at: index)
            let range = NSRange(location: open.start, length: output.length - open.start)
            guard range.length > 0 else { break }
            let size = (output.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)?.pointSize ?? font.pointSize
            switch tag.name {
            case "a": if let url = open.link { output.addAttributes([.link: url, .foregroundColor: NSColor(theme.linkColor)], range: range) }
            case "kbd":
                output.addAttribute(.backgroundColor, value: NSColor(theme.inlineCodeFill), range: range)
                mapFonts(in: range) { .monospacedSystemFont(ofSize: $0.pointSize * 0.94, weight: .regular) }
            case "sub", "sup":
                mapFonts(in: range) { NSFont(descriptor: $0.fontDescriptor, size: $0.pointSize * 0.75) ?? $0 }
                output.addAttribute(.baselineOffset, value: size * (tag.name == "sup" ? 0.36 : -0.16), range: range)
            case "b", "strong": mapFonts(in: range) { $0.adding(.bold) }
            default: mapFonts(in: range) { $0.adding(.italic) }
            }
        }
        return true
    }

    /// `<p align>`/`<div>` wrappers and always-open `<details>`; text inside is literal, whitespace collapsed.
    mutating func renderHTMLBlock(_ raw: String, indent: CGFloat) {
        var start = output.length
        var alignment = NSTextAlignment.natural
        var summaryStart: Int?
        func flush() {
            guard output.length > start else { return }
            if output.mutableString.hasSuffix(" ") { output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1)) }
            let p = style(bodyFont, lineHeight: theme.bodyLineHeight, indent: indent)
            p.alignment = alignment
            endParagraph(from: start, style: p)
            start = output.length
        }
        func text(_ part: Substring) {
            var string = String(part.replacing(#/\s+/#, with: " "))
            if output.length == start { string = String(string.drop { $0 == " " }) }
            for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", "\u{00A0}"), ("&amp;", "&")] {
                string = string.replacingOccurrences(of: entity, with: character)
            }
            if !string.isEmpty { append(string, font: bodyFont) }
        }
        var last = raw.startIndex
        for match in raw.matches(of: #/<[^>]*>/#) {
            text(raw[last..<match.range.lowerBound])
            last = match.range.upperBound
            guard let tag = Self.tag(String(match.output)), Self.blockTags.contains(tag.name) else {
                _ = renderTag(String(match.output), font: bodyFont, color: .labelColor, link: nil)
                continue
            }
            switch (tag.name, tag.closing) {
            case ("summary", false):
                flush()
                append("\u{25BE} ", font: bodyFont, color: secondary)
                summaryStart = output.length
            case ("summary", true):
                if let summaryStart { mapFonts(in: NSRange(location: summaryStart, length: output.length - summaryStart)) { .systemFont(ofSize: $0.pointSize, weight: .semibold) } }
                summaryStart = nil
                flush()
            case (_, let closing):
                flush()
                let align = Self.attribute("align", in: tag.attributes)?.lowercased()
                alignment = closing ? .natural : (align == "center" ? .center : align == "right" ? .right : .natural)
            }
        }
        text(raw[last...])
        flush()
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

extension NSFont {
    func adding(_ trait: NSFontDescriptor.SymbolicTraits) -> NSFont {
        NSFont(descriptor: fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(trait)), size: pointSize) ?? self
    }
}

extension NSAttributedString.Key {
    static let marcoCopy = NSAttributedString.Key("com.dee.marco.copy")
    static let marcoMetadata = NSAttributedString.Key("com.dee.marco.metadata")
}
