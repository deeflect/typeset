import MarcoCore
import SwiftUI

/// Renders one block recursively nested inside a list item or blockquote —
/// a paragraph, heading, code block, nested list, nested quote, table,
/// thematic break, or raw HTML block. These are exactly the shapes
/// `BlockView` dispatches at the top level, reused here so a quote
/// containing a list containing a code block "just works": each level
/// recurses through this same view.
struct StructuredChildView: View {
    let child: StructuredChild
    /// Overrides the paragraph text color (e.g. a completed task item's
    /// text, or a blockquote's muted prose). `nil` keeps the view's own
    /// default.
    var textColor: Color? = nil
    /// How many list levels deep this child is being rendered at, purely
    /// to vary the bullet glyph the way GitHub does (•, ◦, ▪ …). Nesting
    /// indentation itself comes for free from the marker + content HStack
    /// each `ListView` level already builds — no extra offset needed here.
    var listDepth: Int = 0

    var body: some View {
        switch child.kind {
        case .paragraph(let text):
            ParagraphView(raw: text, textColor: textColor, childID: child.id)
        case .heading(let level, let text):
            HeadingView(level: level, text: text, childID: child.id)
        case .codeBlock(let language, let raw):
            CodeBlockView(raw: raw, language: language, childID: child.id)
        case .list(let model):
            ListView(model: model, depth: listDepth + 1)
        case .table(let model):
            TableBlockView(model: model)
        case .quote(let model):
            BlockquoteView(model: model)
        case .thematicBreak:
            ThematicBreakView()
        case .htmlBlock(let raw):
            HTMLBlockView(raw: raw)
        }
    }
}
