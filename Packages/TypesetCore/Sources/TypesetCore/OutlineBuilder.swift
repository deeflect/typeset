import Foundation
import Markdown

/// A single entry in a document's flat outline (table of contents),
/// derived from its top-level heading blocks.
public struct OutlineItem: Identifiable, Equatable, Sendable {
    /// The scroll target: equal to the source heading `Block.id`.
    public let id: String
    public let title: String
    /// Raw heading level (1...6), as written in the source.
    public let level: Int
    /// Normalized indentation depth, 0-based, with skipped levels
    /// collapsed (e.g. an h1 followed directly by an h3 gets depth 1, not
    /// 2, since there is no intervening h2 sibling to indent past).
    public let depth: Int
}

/// Builds a flat outline from a document's parsed `[Block]`, one entry per
/// top-level `.heading` block, in document order.
public enum OutlineBuilder {
    public static func build(from blocks: [Block]) -> [OutlineItem] {
        var items: [OutlineItem] = []
        // Stack of ancestor heading levels currently "open". depth for a
        // new heading is the stack's count after popping any ancestors at
        // the same or a shallower level.
        var stack: [Int] = []

        for block in blocks {
            guard case .heading(let level) = block.kind else { continue }

            while let top = stack.last, top >= level {
                stack.removeLast()
            }
            let depth = stack.count
            stack.append(level)

            var title = plainHeading(block.rawText)
            if title.isEmpty {
                title = block.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if title.isEmpty {
                title = "Untitled"
            }

            items.append(OutlineItem(id: block.id, title: title, level: level, depth: depth))
        }

        return items
    }

    private static func plainHeading(_ source: String) -> String {
        let document = Document(parsing: source)
        guard let heading = document.children.first(where: { $0 is Heading }) else { return source }
        func plain(_ markup: any Markup) -> String {
            if let text = markup as? Markdown.Text { return text.string }
            if let code = markup as? InlineCode { return code.code }
            if markup is SoftBreak || markup is LineBreak { return " " }
            return markup.children.map(plain).joined()
        }
        return plain(heading).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
