import AppKit
import TypesetCore
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
            // Web images never load (R06 remote); an unresolvable source is missing up front.
            let state: ImagePlaceholderCell.State = switch image.url {
            case .some(let url) where url.isFileURL: .loading
            case .some(let url): .remote((url.host ?? "") + url.path)
            case nil: .missing
            }
            attachment.attachmentCell = ImagePlaceholderCell(
                name: image.url?.lastPathComponent ?? (image.alt.isEmpty ? "Image" : image.alt), state: state,
                fill: NSColor(theme.codeCardFill), buttonStroke: NSColor(theme.quoteBar), scale: scale)
            result.addAttribute(.attachment, value: attachment,
                                range: NSRange(location: image.range.location - range.location, length: image.range.length))
        }
        return result
    }

    /// Parse once as a complete document so reference definitions resolve in every block.
    /// `expanded` holds the reader's toggled sections (`metadata`, `metadata-all`, `mdx-imports`,
    /// `details:<summary>`); nil renders statically (Quick Look, export): no toggles, every `<details>` open.
    /// `document`: the body document from `MarkdownParser.parseDocument(source, mdx: isMDX(documentURL))`
    /// for the same source, which skips a second full parse; nil parses here.
    public static func build(source: String, blocks: [Block], document: Markdown.Document? = nil, theme: Theme, documentURL: URL?, metadataExpanded: Bool = true, expanded: Set<String>? = nil) -> Self {
        make(source: source, blocks: blocks, document: document, theme: theme, documentURL: documentURL, metadataExpanded: metadataExpanded, expanded: expanded, cancellable: false)!
    }

    /// Use from a detached reload task; cancelled work never returns a partial document.
    public static func buildCancellable(source: String, blocks: [Block], document: Markdown.Document? = nil, theme: Theme, documentURL: URL?, metadataExpanded: Bool = true, expanded: Set<String>? = nil) throws -> Self {
        guard let result = make(source: source, blocks: blocks, document: document, theme: theme, documentURL: documentURL, metadataExpanded: metadataExpanded, expanded: expanded, cancellable: true) else {
            throw CancellationError()
        }
        return result
    }

    private static func make(source: String, blocks: [Block], document parsed: Markdown.Document?, theme: Theme, documentURL: URL?, metadataExpanded: Bool, expanded: Set<String>?, cancellable: Bool) -> Self? {
        if cancellable && Task<Never, Never>.isCancelled { return nil }
        var writer = Writer(theme: theme, documentURL: documentURL)
        writer.expanded = expanded
        let normalized = source.utf8.contains(UInt8(ascii: "\r")) ? source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") : source
        let lineOffset = MarkdownParser.bodyLineOffset(in: normalized)
        let body = lineOffset == 0 ? normalized : normalized.split(separator: "\n", omittingEmptySubsequences: false).dropFirst(lineOffset).joined(separator: "\n")
        if lineOffset > 0 {
            let metadata = normalized.split(separator: "\n", omittingEmptySubsequences: false).prefix(lineOffset).dropFirst().dropLast().joined(separator: "\n")
            if let block = blocks.first, block.kind == .frontmatter {
                let start = writer.output.length
                let open = expanded.map { $0.contains("metadata") } ?? metadataExpanded
                // The body's leading H1, so the summary row doesn't repeat it as the title.
                let firstLine = body.split(separator: "\n").first { !$0.allSatisfy(\.isWhitespace) }
                let heading = firstLine.flatMap { $0.hasPrefix("# ") ? String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) : nil }
                writer.renderFrontmatter(metadata, expanded: open, showAll: expanded?.contains("metadata-all") ?? true, heading: heading)
                writer.record(block: block, sourceLine: -1, start: start)
            }
        }
        // MDX: ESM and tag lines are blanked for cmark; tag lines render between children by line.
        writer.mdx = MarkdownParser.isMDX(documentURL)
        let mdxNodes = writer.mdx ? MDXScanner.scan(body) : []
        let mdxTags = mdxNodes.filter { $0.kind != .esm }
            .flatMap { node in [(line: node.lines.lowerBound, node: node, closing: false)] + (node.closingLine.map { [(line: $0, node: node, closing: true)] } ?? []) }
            .sorted { $0.line < $1.line }
        var nextTag = 0
        let esm = mdxNodes.filter { $0.kind == .esm }
        if !esm.isEmpty { writer.renderMDXImports(esm) }
        let document = parsed ?? Document(parsing: MarkdownParser.bodyForParsing(mdxNodes.isEmpty ? body : MDXScanner.masked(body, nodes: mdxNodes)))
        if cancellable && Task<Never, Never>.isCancelled { return nil }
        let byLine = Dictionary(uniqueKeysWithValues: blocks.filter { $0.startLine >= 0 }.map { ($0.startLine, $0) })
        func renderTags(before line: Int) {
            while nextTag < mdxTags.count, mdxTags[nextTag].line < line {
                let tag = mdxTags[nextTag]
                let start = writer.output.length
                writer.renderMDXTag(tag.node, closing: tag.closing)
                if let block = byLine[tag.line] { writer.record(block: block, sourceLine: tag.line, start: start) }
                nextTag += 1
            }
        }
        // Escapes and entities can decode into `[^` even when the raw source has no literal marker.
        if body.utf8.contains(where: { $0 == UInt8(ascii: "^") || $0 == UInt8(ascii: "&") }) { writer.numberFootnotes(in: document) }
        for (index, child) in document.children.enumerated() {
            if cancellable && index.isMultiple(of: 32) && Task<Never, Never>.isCancelled { return nil }
            let startLine = (child.range?.lowerBound.line ?? 1) - 1
            renderTags(before: startLine)
            let block = byLine[startLine]
            let start = writer.output.length
            let imageStart = writer.images.count
            let checkboxStart = writer.checkboxes.count
            let codeStart = writer.codeRanges.count
            writer.currentBlockID = block?.id
            writer.openTags = []
            // Inside a collapsed <details>: only HTML blocks run, so the closing tag is still seen.
            if !writer.hidden || child is HTMLBlock { writer.renderBlock(child, blockStartLine: startLine, depth: 0) }
            if let block {
                writer.record(block: block, sourceLine: startLine, start: start,
                              imageStart: imageStart, checkboxStart: checkboxStart, codeStart: codeStart)
            }
        }
        renderTags(before: .max)
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
    var didFootnoteRule = false
    /// `.mdx` document: `{expression}` spans in prose get `renderMDXExpressions`.
    var mdx = false
    /// Toggled sections; nil = static rendering (see `build`).
    var expanded: Set<String>?
    /// Open `<details>`, innermost last: true while collapsed.
    var detailsStack: [Bool] = []
    var hidden: Bool { detailsStack.contains(true) }
    /// Open MDX containers: where their children began and the opening tag to draw.
    var mdxFrames: [(start: Int, tag: String)] = []
    /// Open inline HTML tags; each styles what rendered since its opener when it closes.
    var openTags: [(name: String, start: Int, link: URL?)] = []
    let footnoteRef = #/\[\^([^\]\s]+)\]/#
    let footnoteDefinitionPattern = #/\[\^([^\]\s]+)\]:[ \t]*/#
    // Fonts are made once per build: font creation per node was a measurable share of large builds.
    let bodyFont: NSFont
    let headingFonts: [NSFont]
    let codeFont: NSFont
    /// `adding(_:)` results, keyed by base font and added traits.
    var traitFonts: [TraitFont: NSFont] = [:]
    struct TraitFont: Hashable { let font: NSFont, traits: UInt32 }
    var plainAttributes: [PlainKey: [NSAttributedString.Key: Any]] = [:]
    struct PlainKey: Hashable { let font: NSFont, color: NSColor }
    var secondary: NSColor { .secondaryLabelColor }

    init(theme: Theme, documentURL: URL?) {
        self.theme = theme
        self.documentURL = documentURL
        bodyFont = .systemFont(ofSize: theme.bodySize * theme.scale)
        headingFonts = Self.headingSpecs.map { .systemFont(ofSize: $0.0 * theme.scale, weight: .semibold) }
        codeFont = .monospacedSystemFont(ofSize: 13.5 * theme.scale, weight: .regular)
    }

    /// Heading size, line height, space above, space below, tracking (em), H1…H6.
    static let headingSpecs: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (32, 38, 0, 20, -0.02), (22, 28, 16, 16, -0.01), (18, 24, 8, 16, 0),
        (16, 24, 8, 12, 0), (14, 20, 8, 12, 0), (13, 18, 8, 12, 0)]

    mutating func font(_ font: NSFont, adding trait: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let key = TraitFont(font: font, traits: trait.rawValue)
        if let cached = traitFonts[key] { return cached }
        let made = font.adding(trait)
        traitFonts[key] = made
        return made
    }
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
        ranges.append(.init(id: block.id, sourceLine: sourceLine, range: range, renderedText: output.mutableString.substring(with: range), links: links, images: imageValues, marks: marks))
    }

    mutating func append(_ text: String, font: NSFont, color: NSColor = .labelColor, paragraph: NSParagraphStyle? = nil, extras: [NSAttributedString.Key: Any] = [:]) {
        if paragraph == nil, extras.isEmpty {
            let key = PlainKey(font: font, color: color)
            let attrs = plainAttributes[key] ?? [.font: font, .foregroundColor: color]
            plainAttributes[key] = attrs
            output.append(NSAttributedString(string: text, attributes: attrs))
            return
        }
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
        let text = output.mutableString
        var lineStart = start
        while lineStart < output.length - 1 {
            let newline = text.range(of: "\n", options: [], range: NSRange(location: lineStart, length: output.length - lineStart - 1))
            if newline.location == NSNotFound { break }
            updateStyles(in: NSRange(location: lineStart, length: newline.location - lineStart + 1)) { $0.paragraphSpacing = 0 }
            lineStart = NSMaxRange(newline)
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
        // R04: open <details> bodies sit 24 pt in.
        let indent = CGFloat(depth) * indentStep + CGFloat(detailsStack.count) * 24
        switch node {
        case let heading as Heading:
            let level = min(max(heading.level, 1), 6)
            let (size, lineHeight, before, after, tracking) = Self.headingSpecs[level - 1]
            let font = headingFonts[level - 1]
            let start = output.length
            // H5/H6 step down to secondary; tertiary was near-invisible on both backgrounds.
            renderInline(heading, font: font, color: level < 5 ? .labelColor : secondary)
            if tracking != 0, output.length > start {
                output.addAttribute(.kern, value: size * theme.scale * tracking, range: NSRange(location: start, length: output.length - start))
            }
            endParagraph(from: start, style: style(font, lineHeight: lineHeight, before: before, after: after, indent: indent), font: font)
        case let code as CodeBlock:
            let mono = codeFont
            let block = TypesetTextBlock(.code(language: code.language), color: NSColor(theme.codeCardFill), scale: theme.scale)
            block.setWidth(theme.scaled(indent), type: .absoluteValueType, for: .margin, edge: .minX)
            let p = style(mono, lineHeight: 21, after: 0)
            p.textBlocks = [block]
            let text = code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code
            let start = output.length
            append(text, font: mono, paragraph: p, extras: [.typesetCopy: text])
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
                } else if let ordered {
                    // R01: numerals right-aligned in a 20 pt tabular slot, text at 26.
                    p.tabStops = [NSTextTab(textAlignment: .right, location: theme.scaled(indent + 20)), NSTextTab(textAlignment: .left, location: theme.scaled(indent + indentStep))]
                    let digits = NSFont.monospacedDigitSystemFont(ofSize: bodyFont.pointSize, weight: .regular)
                    append("\t\(Int(ordered.startIndex) + index).\t", font: digits, color: secondary, paragraph: p)
                } else {
                    append(depth > 0 ? "\u{25E6}\t" : "\u{2022}\t", font: bodyFont, color: secondary, paragraph: p)
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
            let block = TypesetTextBlock(.quote, color: alert.map { NSColor(theme.alertTint($0.kind)) } ?? NSColor(theme.quoteBar), scale: theme.scale)
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
            if hidden { break }
            // R09: an unclosed component shows as written (13/20 mono) with a quiet note.
            let unclosed = mdx ? raw.firstMatch(of: #/^<([A-Z][\w.]*)/#).map { String($0.output.1) } : nil
            let mono = NSFont.monospacedSystemFont(ofSize: (unclosed == nil ? 12 : 13) * theme.scale, weight: .regular)
            let start = output.length
            append(raw, font: mono, color: secondary)
            endParagraph(from: start, style: style(mono, lineHeight: unclosed == nil ? 18 : 20, after: unclosed == nil ? 16 : 4, indent: indent), font: mono)
            if let unclosed {
                let font = NSFont.systemFont(ofSize: 12 * theme.scale)
                let note = output.length
                append("<\(unclosed)> isn\u{2019}t closed. Shown as written.", font: font, color: .tertiaryLabelColor)
                endParagraph(from: note, style: style(font, lineHeight: 16, indent: indent), font: font)
            }
        case is ThematicBreak:
            let p = style(bodyFont, lineHeight: 9, after: 0)
            p.textBlocks = [TypesetTextBlock(.rule(length: nil, above: 8, below: 24), color: NSColor(theme.tableStroke), scale: theme.scale)]
            append("\u{00A0}\n", font: bodyFont, paragraph: p)
        case let paragraph as Paragraph where (paragraph.child(at: 0) as? Markdown.Text)?.string.hasPrefix("[^") == true
            && footnoteDefinition(in: Array(paragraph.children), at: 0) != nil:
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
        let headRule = NSColor(theme.tableHeaderRule), stroke = NSColor(theme.tableStroke)
        // One base style per (header?, column); each cell copies it only to set its own text block.
        let bases = [headFont, cellFont].map { font in
            (0..<columns).map { column -> NSParagraphStyle in
                let p = style(font, lineHeight: 20, after: 0)
                if column < table.columnAlignments.count {
                    switch table.columnAlignments[column] {
                    case .some(.center): p.alignment = .center
                    case .some(.right): p.alignment = .right
                    default: p.alignment = .left
                    }
                }
                return p
            }
        }
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
                block.setBorderColor(rowIndex == 0 ? headRule : stroke, for: .maxY)
                let p = bases[rowIndex == 0 ? 0 : 1][min(column, columns - 1)].mutableCopy() as! NSMutableParagraphStyle
                p.textBlocks = [block]
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
        if let text = node as? Markdown.Text {
            let start = output.length
            append(text.string, font: font, color: color, extras: link.map { [.link: $0] } ?? [:])
            if link == nil, Self.mayContainAutolink(text.string) { linkBareURLs(in: text.string, at: start) }
            if mdx { renderMDXExpressions(in: text.string, at: start, font: font) }
            return
        }
        if let code = node as? InlineCode {
            var extras: [NSAttributedString.Key: Any] = [.backgroundColor: NSColor(theme.inlineCodeFill)]
            if let link { extras[.link] = link }
            else { extras[.typesetCopy] = code.code }
            let start = output.length
            append(code.code, font: .monospacedSystemFont(ofSize: font.pointSize * 0.94, weight: .regular), color: color, extras: extras)
            padChip(NSRange(location: start, length: output.length - start))
            return
        }
        if node is SoftBreak {
            // After `<br>` the line already broke; a space would indent the next line.
            if output.length == 0 || output.mutableString.character(at: output.length - 1) != 10 { append(" ", font: font, color: color) }
            return
        }
        if node is LineBreak { append("\n", font: font, color: color); return }
        if let html = node as? InlineHTML {
            if !renderTag(html.rawHTML, font: font, color: color, link: link) { append(html.rawHTML, font: font, color: secondary) }
            return
        }
        if let image = node as? Markdown.Image {
            appendImage(source: image.source, alt: image.children.compactMap { ($0 as? Markdown.Text)?.string }.joined(), font: font, link: link,
                        inline: link != nil || !Self.standsAlone(image))
            return
        }
        var childFont = font
        if node is Strong { childFont = self.font(font, adding: .bold) }
        if node is Emphasis { childFont = self.font(font, adding: .italic) }
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

    // MARK: MDX (board R09)

    /// R09: container JSX opens a hairline frame (closed by its closer line); self-closing JSX is a
    /// 44 pt fill card with a code glyph and the tag in 12 pt mono secondary.
    mutating func renderMDXTag(_ node: MDXNode, closing: Bool) {
        let text = node.source.replacing(#/\s+/#, with: " ").trimmingCharacters(in: .whitespaces)
        if hidden { return }
        switch (node.kind, closing) {
        case (.jsxBlock, false):
            mdxFrames.append((output.length, text))
        case (.jsxBlock, true):
            guard let frame = mdxFrames.popLast() else { return }
            if output.length == frame.start { append("\u{00A0}\n", font: bodyFont, paragraph: style(bodyFont, lineHeight: theme.bodyLineHeight, after: 0)) }
            let range = NSRange(location: frame.start, length: output.length - frame.start)
            let block = TypesetTextBlock(.frame(tag: frame.tag), color: NSColor(theme.hairline), scale: theme.scale)
            updateStyles(in: range) { $0.textBlocks = [block] + $0.textBlocks }
            setSpacingAfterLastParagraph(in: range, 0)
        default:
            let mono = NSFont.monospacedSystemFont(ofSize: 12 * theme.scale, weight: .regular)
            let p = style(mono, lineHeight: 16, after: 0)
            p.textBlocks = [TypesetTextBlock(.box(radius: 8, padY: 14), color: NSColor(theme.codeCardFill), scale: theme.scale)]
            let start = output.length
            let glyph = NSTextAttachment()
            glyph.image = Self.codeGlyph(scale: theme.scale)
            glyph.bounds = NSRect(x: 0, y: (mono.capHeight - theme.scaled(14)) / 2, width: theme.scaled(14), height: theme.scaled(14))
            append("\u{FFFC}", font: mono, color: secondary, extras: [.attachment: glyph])
            space(10, font: mono)
            append(text, font: mono, color: secondary)
            endParagraph(from: start, style: p, font: mono)
        }
    }

    /// R09: ESM never renders as text: one quiet, collapsible "3 imports, 1 export" row.
    mutating func renderMDXImports(_ nodes: [MDXNode]) {
        let lines = nodes.flatMap { $0.source.split(separator: "\n") }
        let imports = lines.filter { $0.hasPrefix("import ") }.count, exports = lines.filter { $0.hasPrefix("export ") }.count
        let parts = [imports > 0 ? "\(imports) import\(imports == 1 ? "" : "s")" : nil, exports > 0 ? "\(exports) export\(exports == 1 ? "" : "s")" : nil]
        let open = expanded?.contains("mdx-imports") == true
        let font = NSFont.systemFont(ofSize: 13 * theme.scale)
        let start = output.length
        appendChevron(open: open, font: font, color: .tertiaryLabelColor, gap: 6)
        append(parts.compactMap { $0 }.joined(separator: ", "), font: font, color: .tertiaryLabelColor)
        if expanded != nil { output.addAttribute(.typesetMetadata, value: "mdx-imports", range: NSRange(location: start, length: output.length - start)) }
        endParagraph(from: start, style: style(font, lineHeight: 24, after: open ? 4 : 16, indent: 4), font: font)
        guard open else { return }
        let mono = NSFont.monospacedSystemFont(ofSize: 12 * theme.scale, weight: .regular)
        let body = output.length
        append(nodes.map(\.source).joined(separator: "\n"), font: mono, color: secondary)
        endParagraph(from: body, style: style(mono, lineHeight: 18, indent: 26), font: mono)
    }

    /// `{expression}` spans in text just appended at `start`: 13 pt mono secondary (R09).
    mutating func renderMDXExpressions(in text: String, at start: Int, font: NSFont) {
        for range in MDXScanner.inlineExpressions(in: text) {
            let span = NSRange(range, in: text)
            output.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: font.pointSize * 13 / 16, weight: .regular), .foregroundColor: secondary],
                                 range: NSRange(location: start + span.location, length: span.length))
        }
    }

    /// The canvas code glyph: 11 pt rounded square with `< >`, tertiary stroke.
    static func codeGlyph(scale: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: 14 * scale, height: 14 * scale), flipped: true) { _ in
            let t = NSAffineTransform()
            t.scale(by: scale)
            t.concat()
            NSColor.tertiaryLabelColor.setStroke()
            let box = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 11, height: 11), xRadius: 2.5, yRadius: 2.5)
            box.lineWidth = 1.2
            box.stroke()
            let brackets = NSBezierPath()
            brackets.move(to: NSPoint(x: 5.5, y: 5)); brackets.line(to: NSPoint(x: 3.75, y: 7)); brackets.line(to: NSPoint(x: 5.5, y: 9))
            brackets.move(to: NSPoint(x: 8.5, y: 5)); brackets.line(to: NSPoint(x: 10.25, y: 7)); brackets.line(to: NSPoint(x: 8.5, y: 9))
            brackets.lineWidth = 1.2
            brackets.lineCapStyle = .round
            brackets.lineJoinStyle = .round
            brackets.stroke()
            return true
        }
    }

    /// The canvas disclosure chevron (10 pt, 1.5 stroke) centred in a 14 pt slot, then `gap` before the label.
    mutating func appendChevron(open: Bool, font: NSFont, color: NSColor, gap: CGFloat) {
        let scale = theme.scale
        let image = NSImage(size: NSSize(width: 14 * scale, height: 10 * scale), flipped: true) { _ in
            let t = NSAffineTransform()
            t.scale(by: scale)
            t.concat()
            ChevronCell.stroke(angle: open ? 90 : 0, color: color)
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: (font.capHeight - 10 * scale) / 2, width: 14 * scale, height: 10 * scale)
        append("\u{FFFC}", font: font, color: color, extras: [.attachment: attachment, .typesetChevronOpen: open])
        space(gap, font: font)
    }

    // MARK: Frontmatter (board R08)

    /// Collapsed: one 24 pt summary row (date · author · tags, or the title-like key + description).
    /// Expanded: description lead, then key/value rows in a 120 pt key slot, closed by a hairline.
    mutating func renderFrontmatter(_ text: String, expanded open: Bool, showAll: Bool, heading: String? = nil) {
        let small = NSFont.systemFont(ofSize: 13 * theme.scale)
        let medium = NSFont.systemFont(ofSize: 13 * theme.scale, weight: .medium)
        let pill = NSFont.systemFont(ofSize: 12 * theme.scale)
        let mono = NSFont.monospacedSystemFont(ofSize: 12 * theme.scale, weight: .regular)
        let interactive = expanded != nil
        let entries = FrontmatterMetadata.entries(text)
        func value(_ key: String) -> FrontmatterValue? { entries?.first { $0.key.lowercased() == key }?.value }
        func string(_ key: String) -> String? {
            switch value(key) {
            case .string(let s)?: return s.isEmpty ? nil : s
            case .list(let items)?: return items.isEmpty ? nil : items.joined(separator: ", ")
            default: return nil
            }
        }
        func dateText(_ v: FrontmatterValue?) -> String? {
            guard case .date(let date, _)? = v else { return nil }
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            f.timeZone = TimeZone(identifier: "UTC")
            return f.string(from: date)
        }

        // Summary row
        let start = output.length
        appendChevron(open: open, font: small, color: .tertiaryLabelColor, gap: 8)
        var shown: Set<String> = []
        if let entries {
            if case .bool(true)? = value("draft") {
                let r = output.length
                append("Draft", font: NSFont.systemFont(ofSize: 12 * theme.scale, weight: .medium), color: NSColor(theme.warn),
                       extras: [.backgroundColor: NSColor(theme.warn.opacity(0.08))])
                padChip(NSRange(location: r, length: output.length - r))
                space(8, font: small)
                shown.insert("draft")
            }
            enum Item { case text(String, NSFont, NSColor), tags([String]) }
            var items: [Item] = []
            let dateKey = value("date") != nil ? "date" : "updated"
            if let date = dateText(value(dateKey)) {
                items.append(.text(date, small, secondary))
                shown.insert(dateKey)
            }
            let authorKey = string("author") != nil ? "author" : "authors"
            if let author = string(authorKey) {
                items.append(.text(author, small, secondary))
                shown.insert(authorKey)
            }
            if case .list(let tags)? = value("tags"), !tags.isEmpty {
                shown.insert("tags")
                items.append(.tags(tags))
            }
            if items.isEmpty {
                // Agent files and plain notes: the title-like key, then the description.
                let titleKey = string("title") != nil ? "title" : "name"
                if let title = string(titleKey) {
                    if title.caseInsensitiveCompare(heading ?? "") != .orderedSame { items.append(.text(title, medium, .labelColor)) }
                    shown.insert(titleKey)
                }
                // Expanded, the description is the lead paragraph below; don't show it twice.
                if open, string("description") != nil {
                    shown.insert("description")
                } else if let description = string("description") {
                    let clipped = description.count > 90 ? description.prefix(89) + "\u{2026}" : Substring(description)
                    items.append(.text(String(clipped), small, secondary))
                    shown.insert("description")
                }
            }
            let more = entries.filter { !shown.contains($0.key.lowercased()) }.count
            // Expanded, every field is listed below.
            if more > 0, !open { items.append(.text("\(more) more", small, secondary)) }
            if items.isEmpty { items.append(.text("Metadata", small, secondary)) }
            for (i, item) in items.enumerated() {
                if i > 0 { space(8, font: small); append("\u{00B7}", font: small, color: .tertiaryLabelColor); space(8, font: small) }
                switch item {
                case .text(let t, let f, let c): append(t, font: f, color: c)
                case .tags(let tags):
                    for (i, tag) in tags.prefix(3).enumerated() {
                        let r = output.length
                        append(tag, font: pill, color: secondary, extras: [.backgroundColor: NSColor(theme.codeCardFill)])
                        padChip(NSRange(location: r, length: output.length - r))
                        if i < min(3, tags.count) - 1 { space(4, font: pill) }
                    }
                    if tags.count > 3 { space(4 + 5, font: pill); append("+\(tags.count - 3)", font: pill, color: .tertiaryLabelColor) }
                }
            }
        } else {
            append("Metadata", font: small, color: secondary)
            space(8, font: small)
            append("\u{00B7} shown as written", font: small, color: .tertiaryLabelColor)
        }
        if interactive { output.addAttribute(.typesetMetadata, value: "metadata", range: NSRange(location: start, length: output.length - start)) }
        endParagraph(from: start, style: style(small, lineHeight: 24, after: open ? 10 : 16, indent: 4), font: small)
        guard open else { return }

        let bodyStart = output.length
        guard let entries else {
            // Malformed: the text as written in a fill box, plus the line that broke.
            let p = style(mono, lineHeight: 18, after: 0)
            let block = TypesetTextBlock(.box(radius: 6, padY: 8), color: NSColor(theme.codeCardFill), scale: theme.scale)
            block.setWidth(theme.scaled(26), type: .absoluteValueType, for: .margin, edge: .minX)
            block.setWidth(theme.scaled(8), type: .absoluteValueType, for: .margin, edge: .maxY)
            p.textBlocks = [block]
            let box = output.length
            append(text, font: mono, paragraph: p)
            endParagraph(from: box, style: p, font: mono)
            setSpacingAfterLastParagraph(in: NSRange(location: box, length: output.length - box), 0)
            if let note = Self.frontmatterProblem(text) {
                let r = output.length
                let font = NSFont.systemFont(ofSize: 12 * theme.scale)
                append(note, font: font, color: .tertiaryLabelColor)
                endParagraph(from: r, style: style(font, lineHeight: 16, after: 0, indent: 26), font: font)
            }
            endFrontmatter(from: bodyStart)
            return
        }
        if case .string(let lead)? = value("description"), !lead.isEmpty {
            let font = NSFont.systemFont(ofSize: 15 * theme.scale)
            let r = output.length
            append(lead, font: font, color: secondary)
            endParagraph(from: r, style: style(font, lineHeight: 23, after: 12, indent: 26), font: font)
        }
        let rows = entries.filter { $0.key.lowercased() != "description" }
        let visible = showAll ? rows : Array(rows.prefix(8))
        let keyFont = small
        for entry in visible {
            let p = style(keyFont, lineHeight: 20, after: 4, indent: 26, head: 26 + 132)
            p.tabStops = [NSTextTab(textAlignment: .left, location: theme.scaled(26 + 132))]
            let r = output.length
            append(entry.key + "\t", font: keyFont, color: secondary)
            switch entry.value {
            case .bool(let b): append(b ? "Yes" : "No", font: small)
            case .number(_, let t): append(t, font: .monospacedDigitSystemFont(ofSize: small.pointSize, weight: .regular))
            case .date(_, let t): append(dateText(entry.value) ?? t, font: small)
            case .string(let v):
                if let url = URL(string: v), ["http", "https"].contains(url.scheme ?? "") {
                    append(v, font: mono, color: NSColor(theme.linkColor), extras: [.link: url])
                } else {
                    append(v, font: Self.isIdentifier(v) ? mono : small)
                }
            case .list(let items):
                append(items.joined(separator: ", "), font: items.allSatisfy(Self.isIdentifier) ? mono : small)
            case .raw(let yaml):
                endParagraph(from: r, style: p, font: keyFont)
                setSpacingAfterLastParagraph(in: NSRange(location: r, length: output.length - r), theme.scaled(2))
                let box = style(mono, lineHeight: 18, after: 0)
                let block = TypesetTextBlock(.box(radius: 6, padY: 6), color: NSColor(theme.codeCardFill), scale: theme.scale)
                block.setWidth(theme.scaled(26 + 132), type: .absoluteValueType, for: .margin, edge: .minX)
                block.setWidth(theme.scaled(10), type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(theme.scaled(4), type: .absoluteValueType, for: .margin, edge: .maxY)
                box.textBlocks = [block]
                let b = output.length
                append(yaml, font: mono, paragraph: box)
                endParagraph(from: b, style: box, font: mono)
                continue
            }
            endParagraph(from: r, style: p, font: keyFont)
        }
        if !showAll, rows.count > visible.count, interactive {
            let r = output.length
            append("Show \(rows.count - visible.count) more fields", font: small, color: NSColor(theme.linkColor), extras: [.typesetMetadata: "metadata-all"])
            endParagraph(from: r, style: style(small, lineHeight: 20, after: 0, indent: 26), font: small)
        }
        endFrontmatter(from: bodyStart)
    }

    /// 20 pt under the fields, a hairline, then the 16 pt block gap.
    mutating func endFrontmatter(from start: Int) {
        setSpacingAfterLastParagraph(in: NSRange(location: start, length: output.length - start), 0)
        let p = style(bodyFont, lineHeight: 1, after: 0)
        p.minimumLineHeight = 1
        p.maximumLineHeight = 1
        p.textBlocks = [TypesetTextBlock(.rule(length: nil, above: 20, below: 16), color: NSColor(theme.hairline), scale: theme.scale)]
        append("\u{00A0}\n", font: bodyFont, paragraph: p)
    }

    /// Paths, slugs, ids and URLs read as mono: one token with a separator in it.
    static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && !value.contains(where: \.isWhitespace) && value.contains(where: { "/._-:".contains($0) })
    }

    /// The first line that breaks the simple `key: value` shape, for the malformed note.
    static func frontmatterProblem(_ text: String) -> String? {
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            for (open, close) in [("[", "]"), ("{", "}")] where line.filter({ String($0) == open }).count > line.filter({ String($0) == close }).count {
                return "Couldn\u{2019}t read line \(i + 1) \u{2014} unclosed \(open)"
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !trimmed.hasPrefix("#"), line.first?.isWhitespace == false, !trimmed.hasPrefix("-"), !line.contains(":") {
                return "Couldn\u{2019}t read line \(i + 1)"
            }
        }
        return nil
    }

    /// `inline`: the image sits in a link or shares its paragraph (README badge rows). A web image there
    /// is a pill like the frontmatter tags (alt, else host) carrying the link, not a 160 pt card.
    mutating func appendImage(source: String?, alt: String, font: NSFont, link: URL?, inline: Bool = false) {
        let url = resolvedURL(source)
        let start = output.length
        if inline, let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            append(alt.isEmpty ? (url.host ?? url.absoluteString) : alt, font: .systemFont(ofSize: 12 * theme.scale), color: secondary,
                   extras: [.backgroundColor: NSColor(theme.codeCardFill), .link: link ?? url])
            padChip(NSRange(location: start, length: output.length - start))
            return
        }
        let attachment = NSTextAttachment()
        var extras: [NSAttributedString.Key: Any] = [.attachment: attachment]
        if let link { extras[.link] = link }
        append("\u{FFFC}", font: font, color: secondary, extras: extras)
        images.append(.init(range: NSRange(location: start, length: output.length - start), url: url, alt: alt))
    }

    /// Nothing but whitespace beside the image in its paragraph (or other container).
    static func standsAlone(_ image: Markdown.Image) -> Bool {
        guard let parent = image.parent else { return true }
        return parent.children.allSatisfy { child in
            child.indexInParent == image.indexInParent || child is SoftBreak || child is LineBreak
                || (child as? Markdown.Text)?.string.allSatisfy(\.isWhitespace) == true
        }
    }

    static let linkDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Cheap byte pre-check before running the detector: `://`, `www.` or `@`.
    static func mayContainAutolink(_ text: String) -> Bool {
        var window: UInt32 = 0
        for byte in text.utf8 {
            if byte == UInt8(ascii: "@") { return true }
            window = window << 8 | UInt32(byte)
            if window & 0xFFFFFF == 0x3A2F2F || window == 0x7777772E { return true } // "://", "www."
        }
        return false
    }

    /// GFM autolinks in plain text just appended at `start` (swift-markdown doesn't enable that extension):
    /// `http(s)://…`, `www.…` (as https) and emails (as mailto), the schemes the reader opens.
    mutating func linkBareURLs(in text: String, at start: Int) {
        let ns = text as NSString
        for match in Self.linkDetector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard var url = match.url else { continue }
            let literal = ns.substring(with: match.range)
            let lower = literal.lowercased()
            if lower.hasPrefix("www.") {
                guard let https = URL(string: "https://" + literal) else { continue }
                url = https
            } else if !(lower.hasPrefix("http://") || lower.hasPrefix("https://") || url.scheme == "mailto") {
                continue
            }
            output.addAttributes([.link: url, .foregroundColor: NSColor(theme.linkColor)],
                                 range: NSRange(location: start + match.range.location, length: match.range.length))
        }
    }

    /// Chips (inline code, keycaps) get 5 pt of side padding as kerning, so the drawn fill never covers neighbours.
    mutating func padChip(_ range: NSRange) {
        guard range.length > 0 else { return }
        let pad = theme.scaled(5)
        output.addAttribute(.kern, value: pad, range: NSRange(location: NSMaxRange(range) - 1, length: 1))
        guard range.location > 0, output.mutableString.character(at: range.location - 1) != 10 else { return }
        if output.attribute(.backgroundColor, at: range.location - 1, effectiveRange: nil) != nil
            || output.attribute(.attachment, at: range.location - 1, effectiveRange: nil) != nil {
            // Adjacent chips (⌘K) or a glyph before the chip: a 4 pt spacer keeps the fills apart.
            let font = output.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? bodyFont
            output.insert(NSAttributedString(string: " ", attributes: [.font: font, .kern: theme.scaled(4) + pad - Self.spaceWidth(font)]), at: range.location)
            return
        }
        let previous = output.attribute(.kern, at: range.location - 1, effectiveRange: nil) as? CGFloat ?? 0
        output.addAttribute(.kern, value: previous + pad, range: NSRange(location: range.location - 1, length: 1))
    }

    /// A plain space whose advance is exactly `points` (scaled): gaps after glyphs and between pills.
    mutating func space(_ points: CGFloat, font: NSFont) {
        append(" ", font: font, extras: [.kern: theme.scaled(points) - Self.spaceWidth(font)])
    }

    static func spaceWidth(_ font: NSFont) -> CGFloat {
        (" " as NSString).size(withAttributes: [.font: font]).width
    }

    mutating func mapFonts(in range: NSRange, _ change: (NSFont) -> NSFont) {
        var runs: [(NSRange, NSFont)] = []
        output.enumerateAttribute(.font, in: range) { value, run, _ in if let font = value as? NSFont { runs.append((run, font)) } }
        for (run, font) in runs { output.addAttribute(.font, value: change(font), range: run) }
    }

    // MARK: GitHub alerts

    struct Alert { let label: String, symbol: String, kind: Theme.AlertKind }

    /// GitHub's rule: the quote's first line is exactly `[!KIND]`, any case.
    static func alert(_ quote: BlockQuote) -> Alert? {
        guard let paragraph = quote.child(at: 0) as? Paragraph,
              let marker = (paragraph.child(at: 0) as? Markdown.Text)?.string,
              paragraph.childCount == 1 || paragraph.child(at: 1) is SoftBreak || paragraph.child(at: 1) is LineBreak else { return nil }
        switch marker.trimmingCharacters(in: .whitespaces).lowercased() {
        case "[!note]": return Alert(label: "Note", symbol: "info.circle", kind: .note)
        case "[!tip]": return Alert(label: "Tip", symbol: "lightbulb", kind: .tip)
        case "[!important]": return Alert(label: "Important", symbol: "exclamationmark.bubble", kind: .important)
        case "[!warning]": return Alert(label: "Warning", symbol: "exclamationmark.triangle", kind: .warning)
        case "[!caution]": return Alert(label: "Caution", symbol: "exclamationmark.octagon", kind: .caution)
        default: return nil
        }
    }

    mutating func renderAlertTitle(_ alert: Alert, indent: CGFloat) {
        // R01: 14/20 semibold title, 14 pt glyph, 6 pt glyph gap, 4 pt to the body.
        let tint = NSColor(theme.alertTint(alert.kind))
        let font = NSFont.systemFont(ofSize: 14 * theme.scale, weight: .semibold)
        let start = output.length
        let attachment = NSTextAttachment()
        if let image = NSImage(systemSymbolName: alert.symbol, accessibilityDescription: alert.label)?
            .withSymbolConfiguration(.init(pointSize: 14 * theme.scale * 0.86, weight: .semibold).applying(.init(paletteColors: [tint]))) {
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: (font.capHeight - image.size.height) / 2, width: image.size.width, height: image.size.height)
        }
        append("\u{FFFC}", font: font, color: tint, extras: [.attachment: attachment])
        space(6, font: font)
        append(alert.label, font: font, color: tint)
        endParagraph(from: start, style: style(font, lineHeight: 20, after: 4, indent: indent), font: font)
    }

    // MARK: Footnotes (swift-markdown leaves `[^label]` as text)

    /// `[^label]: rest` at the start of a paragraph line.
    func footnoteDefinition(in children: [any Markup], at index: Int) -> (label: String, rest: String)? {
        guard index < children.count, index == 0 || children[index - 1] is SoftBreak || children[index - 1] is LineBreak,
              let text = (children[index] as? Markdown.Text)?.string,
              text.hasPrefix("[^"),
              let match = text.prefixMatch(of: footnoteDefinitionPattern) else { return nil }
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
                if node is Paragraph, let definition = footnoteDefinition(in: children, at: index) {
                    defined.insert(definition.label)
                    text = definition.rest
                }
                for match in text.matches(of: footnoteRef) where !order.contains(match.1.lowercased()) { order.append(match.1.lowercased()) }
            }
        }
        scan(document)
        for label in order where defined.contains(label) { footnoteNumbers[label] = footnoteNumbers.count + 1 }
    }

    /// Text with `[^label]` references as small raised links to `#fn-label`.
    mutating func renderFootnoteText(_ string: String, font: NSFont, color: NSColor, link: URL?) {
        var last = string.startIndex
        for match in string.matches(of: footnoteRef) {
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
        if !didFootnoteRule {
            // R05: a 120 pt hairline opens the first footnote block, 16 above and 8 below.
            didFootnoteRule = true
            setSpacingAfterLastParagraph(in: NSRange(location: 0, length: output.length), 0)
            let rule = style(bodyFont, lineHeight: 1, after: 0)
            rule.minimumLineHeight = 1
            rule.maximumLineHeight = 1
            rule.textBlocks = [TypesetTextBlock(.rule(length: 120, above: output.length > 0 ? 16 : 0, below: 8), color: NSColor(theme.hairline), scale: theme.scale)]
            append("\u{00A0}\n", font: bodyFont, paragraph: rule)
        }
        let digits = NSFont.monospacedDigitSystemFont(ofSize: 13 * theme.scale, weight: .regular)
        let blockStart = output.length
        var start = output.length
        let children = Array(paragraph.children)
        for (index, child) in children.enumerated() {
            if let definition = footnoteDefinition(in: children, at: index) {
                if output.length > start { endParagraph(from: start, style: p, font: font) }
                start = output.length
                let number = footnoteNumbers[definition.label] ?? footnoteNumbers.count + 1
                footnoteNumbers[definition.label] = number
                if let currentBlockID { footnoteBlockIDs["fn-\(definition.label)"] = currentBlockID }
                append("\(number).\t", font: digits, color: .tertiaryLabelColor)
                if (definition.rest.hasPrefix("https://") || definition.rest.hasPrefix("http://")),
                   !definition.rest.contains(where: \.isWhitespace), let url = URL(string: definition.rest) {
                    append(definition.rest, font: font, color: NSColor(theme.linkColor), extras: [.link: url])
                } else {
                    renderFootnoteText(definition.rest, font: font, color: secondary, link: nil)
                }
            } else if child is SoftBreak || child is LineBreak, footnoteDefinition(in: children, at: index + 1) != nil {
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
            if !tag.closing {
                let anchor = openTags.last { $0.name == "a" }
                appendImage(source: Self.attribute("src", in: tag.attributes), alt: Self.attribute("alt", in: tag.attributes) ?? "", font: font,
                            link: link ?? anchor?.link, inline: link != nil || anchor != nil)
            }
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
                // R01 keycap: page fill, keycap stroke (2 pt bottom), radius 4, sans 13; drawn by ChipLayoutManager.
                output.addAttributes([.backgroundColor: NSColor(theme.background), .typesetKeycap: NSColor(theme.keycapStroke)], range: range)
                let body = theme.bodySize * theme.scale, cap = 13 * theme.scale
                mapFonts(in: range) { .systemFont(ofSize: cap * $0.pointSize / body) }
                padChip(range)
            case "sub", "sup":
                mapFonts(in: range) { NSFont(descriptor: $0.fontDescriptor, size: $0.pointSize * 0.75) ?? $0 }
                output.addAttribute(.baselineOffset, value: size * (tag.name == "sup" ? 0.36 : -0.16), range: range)
            case "b", "strong": mapFonts(in: range) { $0.adding(.bold) }
            default: mapFonts(in: range) { $0.adding(.italic) }
            }
        }
        return true
    }

    /// `<p align>`/`<div>` wrappers and collapsible `<details>` (R04); text inside is literal, whitespace collapsed.
    mutating func renderHTMLBlock(_ raw: String, indent: CGFloat) {
        var start = output.length
        var alignment = NSTextAlignment.natural
        var summaryStart: Int?
        var detailsOpenAttribute = false
        func flush() {
            guard output.length > start, !hidden else { return }
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
            if !string.isEmpty, !hidden { append(string, font: bodyFont) }
        }
        var last = raw.startIndex
        for match in raw.matches(of: #/<[^>]*>/#) {
            text(raw[last..<match.range.lowerBound])
            last = match.range.upperBound
            guard let tag = Self.tag(String(match.output)), Self.blockTags.contains(tag.name) else {
                if !hidden { _ = renderTag(String(match.output), font: bodyFont, color: .labelColor, link: nil) }
                continue
            }
            switch (tag.name, tag.closing) {
            case ("details", false):
                flush()
                detailsOpenAttribute = tag.attributes.firstMatch(of: #/(^|\s)open(\s|=|$)/#) != nil
            case ("details", true):
                flush()
                _ = detailsStack.popLast()
            case ("summary", false):
                flush()
                summaryStart = output.length
            case ("summary", true):
                guard let from = summaryStart else { continue }
                summaryStart = nil
                if hidden { detailsStack.append(true); continue }
                let label = output.attributedSubstring(from: NSRange(location: from, length: output.length - from)).string
                let key = "details:" + label.trimmingCharacters(in: .whitespaces)
                let collapsed = expanded.map { detailsOpenAttribute == $0.contains(key) } ?? false
                let font = NSFont.systemFont(ofSize: 16 * theme.scale, weight: .semibold)
                output.addAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: NSRange(location: from, length: output.length - from))
                let labelEnd = output.length
                appendChevron(open: !collapsed, font: font, color: secondary, gap: 6)
                let chevron = output.attributedSubstring(from: NSRange(location: labelEnd, length: output.length - labelEnd))
                output.deleteCharacters(in: NSRange(location: labelEnd, length: output.length - labelEnd))
                output.insert(chevron, at: from)
                // The label's images and open tags moved right by the chevron.
                var i = images.count - 1
                while i >= 0, images[i].range.location >= from {
                    let image = images[i]
                    images[i] = .init(range: NSRange(location: image.range.location + chevron.length, length: image.range.length), url: image.url, alt: image.alt)
                    i -= 1
                }
                openTags = openTags.map { $0.start >= from ? ($0.name, $0.start + chevron.length, $0.link) : $0 }
                if expanded != nil { output.addAttribute(.typesetMetadata, value: key, range: NSRange(location: from, length: output.length - from)) }
                endParagraph(from: from, style: style(font, lineHeight: 26, after: collapsed ? 16 : 6, indent: indent + 4), font: font)
                start = output.length
                detailsStack.append(collapsed)
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
    static let typesetCopy = NSAttributedString.Key("com.dee.typeset.copy")
    static let typesetMetadata = NSAttributedString.Key("com.dee.typeset.metadata")
    /// On a toggle chevron: whether it points down (open). The reading view rotates it on toggle.
    static let typesetChevronOpen = NSAttributedString.Key("com.dee.typeset.chevron-open")
    /// Keycap stroke color on `<kbd>` runs; `ChipLayoutManager` draws the cap.
    static let typesetKeycap = NSAttributedString.Key("com.dee.typeset.keycap")
}
