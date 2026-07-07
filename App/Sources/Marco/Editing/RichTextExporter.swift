import AppKit
import MarcoCore
import SwiftUI
import MarcoRendering

/// Converts the rendered document to `NSAttributedString`, reusing
/// `Theme`'s fonts/colors and `InlineMarkdown`'s inline styling (bold /
/// italic / links / inline code), for PLAN §2 J5: Copy as Rich Text
/// (⌘⇧C) and PDF export/print (⌘⇧E / ⌘P) share this one builder.
@MainActor
enum RichTextExporter {
    static func build(blocks: [Block], theme: Theme) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for block in blocks {
            result.append(attributedString(for: block, theme: theme, depth: 0))
        }
        return result
    }

    // MARK: - Pasteboard (Copy as Rich Text)

    /// Puts RTF, HTML, and plain Markdown representations of `text` on the
    /// general pasteboard, in that preference order, so pasting into rich
    /// text apps (Notes, Mail, Notion, Google Docs) picks up formatting
    /// while plain-text targets still get sensible Markdown source.
    static func copyAsRichText(blocks: [Block], theme: Theme, plainMarkdown: String) {
        let attributed = build(blocks: blocks, theme: theme)
        let fullRange = NSRange(location: 0, length: attributed.length)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var items: [(NSPasteboard.PasteboardType, Data)] = []
        if let rtf = try? attributed.data(from: fullRange, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            items.append((.rtf, rtf))
        }
        if let html = try? attributed.data(from: fullRange, documentAttributes: [.documentType: NSAttributedString.DocumentType.html]) {
            items.append((.html, html))
        }
        for (type, data) in items {
            pasteboard.setData(data, forType: type)
        }
        pasteboard.setString(plainMarkdown, forType: .string)
    }

    // MARK: - Block conversion

    private static func attributedString(for block: Block, theme: Theme, depth: Int) -> NSAttributedString {
        switch block.kind {
        case .frontmatter:
            return NSAttributedString(string: "")
        case .heading(let level):
            let text = BlockStructureCache.shared.headingText(for: block)
            return heading(text: text, level: level, theme: theme)
        case .paragraph:
            return paragraph(raw: block.rawText, theme: theme)
        case .codeBlock:
            return codeBlock(raw: CodeBlockView.extractCode(block.rawText), theme: theme)
        case .list:
            if let model = BlockStructureCache.shared.list(for: block) {
                return list(model, theme: theme, depth: depth)
            }
            return plain(block.rawText, theme: theme)
        case .table:
            if let model = BlockStructureCache.shared.table(for: block) {
                return table(model, theme: theme)
            }
            return plain(block.rawText, theme: theme)
        case .blockquote:
            if let model = BlockStructureCache.shared.quote(for: block) {
                return quote(model, theme: theme, depth: depth)
            }
            return plain(block.rawText, theme: theme)
        case .thematicBreak:
            return trailer("\u{2014}\u{2014}\u{2014}\n\n", font: .systemFont(ofSize: theme.bodySize), color: NSColor(theme.thematicBreak))
        case .htmlBlock:
            return plain(block.rawText, theme: theme)
        }
    }

    private static func heading(text: String, level: Int, theme: Theme) -> NSAttributedString {
        let style = theme.heading(level: level)
        let font: NSFont = {
            switch level {
            case 1: return .boldSystemFont(ofSize: 22)
            case 2: return .boldSystemFont(ofSize: 18)
            case 3: return .boldSystemFont(ofSize: 15.5)
            default: return .boldSystemFont(ofSize: 13.5)
            }
        }()
        let attributed = inline(text, theme: theme)
        let result = NSMutableAttributedString(attributedString: attributed)
        result.addAttribute(.font, value: font, range: NSRange(location: 0, length: result.length))
        result.addAttribute(.foregroundColor, value: NSColor(style.color), range: NSRange(location: 0, length: result.length))
        result.append(NSAttributedString(string: "\n\n"))
        return result
    }

    private static func paragraph(raw: String, theme: Theme) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: inline(raw, theme: theme))
        result.append(NSAttributedString(string: "\n\n"))
        return result
    }

    private static func codeBlock(raw: String, theme: Theme) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = 12
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(theme.textPrimary),
            .backgroundColor: NSColor(theme.codeCardFill),
            .paragraphStyle: paragraphStyle
        ]
        let result = NSMutableAttributedString(string: raw, attributes: attributes)
        result.append(NSAttributedString(string: "\n\n"))
        return result
    }

    private static func list(_ model: ListModel, theme: Theme, depth: Int) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let indent = String(repeating: "    ", count: depth)
        for (index, item) in model.items.enumerated() {
            let bullet: String
            if item.checkbox != nil {
                bullet = item.checkbox == .checked ? "\u{2611} " : "\u{2610} "
            } else if model.isOrdered {
                bullet = "\(model.start + index). "
            } else {
                bullet = "\u{2022} "
            }
            result.append(NSAttributedString(
                string: indent + bullet,
                attributes: [.font: NSFont.systemFont(ofSize: theme.bodySize), .foregroundColor: NSColor(theme.textSecondary)]))
            for (childIndex, child) in item.children.enumerated() {
                if childIndex > 0 { result.append(NSAttributedString(string: indent + "  ")) }
                result.append(structuredChild(child, theme: theme, depth: depth + 1))
            }
        }
        result.append(NSAttributedString(string: "\n"))
        return result
    }

    private static func structuredChild(_ child: StructuredChild, theme: Theme, depth: Int) -> NSAttributedString {
        switch child.kind {
        case .paragraph(let text):
            return NSMutableAttributedString(attributedString: inline(text, theme: theme)).appendingNewline()
        case .heading(let level, let text):
            return heading(text: text, level: level, theme: theme)
        case .codeBlock(_, let raw):
            return codeBlock(raw: CodeBlockView.extractCode(raw), theme: theme)
        case .list(let model):
            return list(model, theme: theme, depth: depth)
        case .table(let model):
            return table(model, theme: theme)
        case .quote(let model):
            return quote(model, theme: theme, depth: depth)
        case .thematicBreak:
            return NSAttributedString(string: "\u{2014}\u{2014}\u{2014}\n")
        case .htmlBlock(let raw):
            return plain(raw, theme: theme)
        }
    }

    private static func table(_ model: TableModel, theme: Theme) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: theme.bodySize), .foregroundColor: NSColor(theme.textPrimary)
        ]
        result.append(NSAttributedString(string: model.header.joined(separator: " \u{2502} ") + "\n", attributes: headerAttrs))
        result.append(NSAttributedString(
            string: String(repeating: "\u{2500}", count: 40) + "\n",
            attributes: [.foregroundColor: NSColor(theme.tableStroke)]))
        for row in model.rows {
            result.append(inline(row.joined(separator: " \u{2502} "), theme: theme))
            result.append(NSAttributedString(string: "\n"))
        }
        result.append(NSAttributedString(string: "\n"))
        return result
    }

    private static func quote(_ model: QuoteModel, theme: Theme, depth: Int) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "\u{2503} ", attributes: [.foregroundColor: NSColor(theme.quoteBar)])
        for child in model.children {
            result.append(structuredChild(child, theme: theme, depth: depth))
        }
        result.append(NSAttributedString(string: "\n"))
        return result
    }

    private static func plain(_ text: String, theme: Theme) -> NSAttributedString {
        NSAttributedString(
            string: text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: theme.bodySize), .foregroundColor: NSColor(theme.textTertiary)])
    }

    private static func trailer(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    /// Converts a block's inline Markdown source to `NSAttributedString`,
    /// reusing `InlineMarkdown`'s existing parse (bold / italic / links /
    /// inline code / strikethrough, plus the theme's code/link colors) so
    /// exports match the reading view. Built run-by-run rather than via a
    /// direct `NSAttributedString(AttributedString)` bridge: SwiftUI's
    /// `inlinePresentationIntent` (how bold/italic/code are actually
    /// represented) isn't guaranteed to bridge to NSFont traits, so traits
    /// are resolved explicitly here instead of relying on that conversion.
    private static func inline(_ raw: String, theme: Theme) -> NSAttributedString {
        let attributed = InlineMarkdown.attributed(raw, theme: theme)
        let result = NSMutableAttributedString()
        let baseFont = NSFont.systemFont(ofSize: theme.bodySize)

        for run in attributed.runs {
            let substring = String(attributed[run.range].characters)
            guard !substring.isEmpty else { continue }

            var font = baseFont
            var traits: NSFontTraitMask = []
            var codeBackground = false
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                if intent.contains(.code) {
                    font = NSFont.monospacedSystemFont(ofSize: theme.inlineCodeSize, weight: .regular)
                    // Inline code no longer carries a `backgroundColor` (the
                    // reading view draws its chip via a `TextRenderer`), so add
                    // the fill here to keep exported RTF looking the same.
                    codeBackground = true
                }
            }
            if !traits.isEmpty {
                font = NSFontManager.shared.convert(font, toHaveTrait: traits)
            }

            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            attributes[.foregroundColor] = NSColor(run.foregroundColor ?? theme.textPrimary)
            if let background = run.backgroundColor {
                attributes[.backgroundColor] = NSColor(background)
            } else if codeBackground {
                attributes[.backgroundColor] = NSColor(theme.inlineCodeFill)
            }
            if run.inlinePresentationIntent?.contains(.strikethrough) == true {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor(theme.linkColor)
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: substring, attributes: attributes))
        }
        return result
    }
}

private extension NSMutableAttributedString {
    func appendingNewline() -> NSAttributedString {
        append(NSAttributedString(string: "\n"))
        return self
    }
}
