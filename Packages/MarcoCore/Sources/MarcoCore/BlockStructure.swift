import Markdown

/// Recursive block-level content nested inside a list item or blockquote
/// (a list item can contain a code block, a blockquote can contain a list
/// containing a code block, etc). Built from the real cmark-gfm AST rather
/// than guessed from raw text, so nesting, loose/tight spacing, and code
/// spans inside table cells all follow actual GFM semantics.
public struct StructuredChild: Equatable, Sendable, Identifiable {
    public let id: Int
    public let kind: Kind

    public indirect enum Kind: Equatable, Sendable {
        case paragraph(String)
        case heading(level: Int, text: String)
        /// `raw` is a synthesized fenced block (```` ``` ```` + language +
        /// code + ```` ``` ````) so it can be handed straight to
        /// `CodeBlockView`, whose `extractCode` is unchanged.
        case codeBlock(language: String?, raw: String)
        case list(ListModel)
        case table(TableModel)
        case quote(QuoteModel)
        case thematicBreak
        case htmlBlock(String)
    }
}

/// A parsed ordered or unordered list: true nested depth (via recursive
/// `StructuredChild.list`), the real ordered-list start index, and whether
/// cmark considers the list "loose" (renders items with paragraph spacing)
/// or "tight".
public struct ListModel: Equatable, Sendable {
    public var isOrdered: Bool
    public var start: Int
    public var isLoose: Bool
    public var items: [Item]

    public struct Item: Equatable, Sendable, Identifiable {
        public let id: Int
        public var checkbox: TaskState?
        public var children: [StructuredChild]
    }
}

public enum TaskState: Equatable, Sendable {
    case checked
    case unchecked
}

/// A parsed GFM table. Cell text is the cell's inline content
/// re-serialized to Markdown source (so `InlineMarkdown` can render bold/
/// links/inline code inside cells), split by the real AST rather than by
/// scanning for unescaped `|` — a pipe inside a code span never splits a
/// cell.
public struct TableModel: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable {
        case leading
        case center
        case trailing
    }

    public var alignments: [Alignment]
    public var header: [String]
    public var rows: [[String]]
}

/// A parsed blockquote. `children` are the quote's direct block content —
/// which may themselves be another `QuoteModel` (nested `>>` quotes),
/// letting a quote contain a list containing a code block.
public struct QuoteModel: Equatable, Sendable {
    public var children: [StructuredChild]
}

/// Builds the typed models above by parsing a single block's `rawText`
/// with swift-markdown (`Document(parsing:)`, GFM extensions on by
/// default) and walking the resulting AST — rather than hand-rolling line
/// scanners. Each entry point re-parses just that block's own text as a
/// tiny standalone document; callers should go through
/// `BlockStructureCache` so this only happens once per distinct block.
public enum BlockStructure {

    /// Resolves a heading block's inline text straight from its parsed
    /// inline children, so e.g. `"# C#"` renders as `"C#"` — no generic
    /// trailing-`#` stripping that would also eat a language name.
    public static func headingText(_ raw: String) -> String {
        let document = Document(parsing: raw)
        guard let heading = document.children.first(where: { $0 is Heading }) as? Heading else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return headingText(of: heading)
    }

    public static func list(_ raw: String) -> ListModel? {
        let document = Document(parsing: raw)
        guard let node = document.children.first(where: { $0 is OrderedList || $0 is UnorderedList }) else {
            return nil
        }
        return listModel(from: node, idGen: IDGenerator())
    }

    public static func table(_ raw: String) -> TableModel? {
        let document = Document(parsing: raw)
        guard let table = document.children.first(where: { $0 is Table }) as? Table else { return nil }
        return tableModel(from: table)
    }

    public static func quote(_ raw: String) -> QuoteModel? {
        let document = Document(parsing: raw)
        guard let quote = document.children.first(where: { $0 is BlockQuote }) as? BlockQuote else { return nil }
        return QuoteModel(children: childBlocks(of: quote, idGen: IDGenerator()))
    }

    // MARK: - AST walk

    /// Assigns stable, unique ids to `StructuredChild`/`ListModel.Item`
    /// values as a single tree is walked, for `ForEach` identity.
    private final class IDGenerator {
        private var next = 0
        func nextID() -> Int {
            defer { next += 1 }
            return next
        }
    }

    /// Re-serializes a heading's inline content (bold/italic/links/inline
    /// code, etc.) back to Markdown source text, suitable as input to
    /// `InlineMarkdown.attributed`.
    ///
    /// Formats the whole (detached) heading in one pass, rather than
    /// joining each inline child's own `.format()` — a lone soft line break
    /// mid-heading only emits its separating space/newline when the
    /// formatter walks the whole subtree in sequence; formatting it in
    /// isolation (as one child among several) drops the separator and runs
    /// adjacent words together. Detaching first (see `blockInlineText`)
    /// keeps a heading nested inside a quote/list item from leaking that
    /// ancestor's `> ` / indentation prefix into the text, and the fixed
    /// `"#"*level + " "` ATX prefix this produces is then trimmed
    /// deterministically — unlike stripping *every* trailing `#`, which
    /// would also eat a heading that legitimately ends in one (`"# C#"`).
    private static func headingText(of heading: Heading) -> String {
        var text = heading.detachedFromParent.format()
        let atxPrefix = String(repeating: "#", count: heading.level) + " "
        if text.hasPrefix(atxPrefix) {
            text.removeFirst(atxPrefix.count)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Re-serializes any other inline-bearing block (chiefly `Paragraph`)
    /// back to Markdown source text. See `headingText(of:)` for why this
    /// formats the whole detached node in one pass instead of joining
    /// per-child `.format()` calls.
    private static func blockInlineText(of markup: any Markup) -> String {
        markup.detachedFromParent.format().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Re-serializes a table cell's inline content back to Markdown source
    /// text. Cells can't contain a soft/hard line break in GFM (the `|`
    /// delimited row syntax is confined to one physical line), so the
    /// whole-node-format concern above doesn't apply here — and `Table.Cell`
    /// can't be formatted standalone at all (swift-markdown requires
    /// formatting a table as a single unit), so children are joined
    /// individually instead. Detaching the cell first still matters, so a
    /// cell in a table nested inside a quote doesn't leak a `> ` prefix.
    private static func cellText(of cell: Table.Cell) -> String {
        cell.detachedFromParent.children.map { $0.format() }.joined()
    }

    private static func childBlocks(of container: any Markup, idGen: IDGenerator) -> [StructuredChild] {
        container.children.map { structuredChild(for: $0, idGen: idGen) }
    }

    private static func structuredChild(for markup: any Markup, idGen: IDGenerator) -> StructuredChild {
        let id = idGen.nextID()
        switch markup {
        case let heading as Heading:
            return StructuredChild(id: id, kind: .heading(level: heading.level, text: headingText(of: heading)))
        case let codeBlock as CodeBlock:
            return StructuredChild(id: id, kind: .codeBlock(language: codeBlock.language, raw: fenced(codeBlock)))
        case is UnorderedList, is OrderedList:
            // listModel(from:idGen:) only returns nil for a markup that is
            // neither of these two cases, which can't happen here.
            return StructuredChild(id: id, kind: .list(listModel(from: markup, idGen: idGen)!))
        case let table as Table:
            return StructuredChild(id: id, kind: .table(tableModel(from: table)))
        case let quote as BlockQuote:
            return StructuredChild(id: id, kind: .quote(QuoteModel(children: childBlocks(of: quote, idGen: idGen))))
        case is ThematicBreak:
            return StructuredChild(id: id, kind: .thematicBreak)
        case let html as HTMLBlock:
            return StructuredChild(id: id, kind: .htmlBlock(html.rawHTML))
        default:
            // Paragraph, and anything else we don't special-case.
            return StructuredChild(id: id, kind: .paragraph(blockInlineText(of: markup)))
        }
    }

    /// Wraps a code block's already-dedented `code` back in a fence so it
    /// can flow through the unmodified `CodeBlockView.extractCode`.
    private static func fenced(_ codeBlock: CodeBlock) -> String {
        var code = codeBlock.code
        if code.hasSuffix("\n") { code.removeLast() }
        return "```\(codeBlock.language ?? "")\n\(code)\n```"
    }

    private static func listModel(from markup: any Markup, idGen: IDGenerator) -> ListModel? {
        let isOrdered: Bool
        let start: Int
        switch markup {
        case let ordered as OrderedList:
            isOrdered = true
            start = Int(ordered.startIndex)
        case is UnorderedList:
            isOrdered = false
            start = 1
        default:
            return nil
        }

        let listItems = markup.children.compactMap { $0 as? ListItem }
        let items = listItems.map { item in
            ListModel.Item(
                id: idGen.nextID(),
                checkbox: item.checkbox.map { $0 == .checked ? .checked : .unchecked },
                children: childBlocks(of: item, idGen: idGen))
        }
        return ListModel(isOrdered: isOrdered, start: start, isLoose: isLoose(listItems), items: items)
    }

    /// A list is "loose" (CommonMark's term for items rendered with
    /// paragraph spacing rather than snug together) exactly when a blank
    /// source line separates any two of its items' block-level children —
    /// including between the last block of one item and the first block of
    /// the next. Comparing each child's real parsed `range` is the actual
    /// cmark rule, not a guess from indentation.
    private static func isLoose(_ items: [ListItem]) -> Bool {
        var previousEndLine: Int?
        for item in items {
            for child in item.children {
                guard let range = child.range else { continue }
                if let previousEndLine, range.lowerBound.line > previousEndLine + 1 {
                    return true
                }
                previousEndLine = range.upperBound.line
            }
        }
        return false
    }

    private static func tableModel(from table: Table) -> TableModel {
        let alignments = table.columnAlignments.map { alignment -> TableModel.Alignment in
            switch alignment {
            case .left, .none: return .leading
            case .center: return .center
            case .right: return .trailing
            }
        }
        return TableModel(
            alignments: alignments,
            header: table.head.cells.map { cellText(of: $0) },
            rows: table.body.rows.map { row in row.cells.map { cellText(of: $0) } })
    }
}
