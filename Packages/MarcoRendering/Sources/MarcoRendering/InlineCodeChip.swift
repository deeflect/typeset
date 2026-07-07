import SwiftUI

/// How an inline-code chip is currently drawn. `normal` is the resting quiet
/// fill; `flash` is the transient accent fill during the click-to-copy
/// acknowledgment (see `applyingCopiedFlash`).
public enum InlineCodeChipStyle: Hashable, Sendable {
    case normal
    case flash
}

/// AttributedString-side marker on an inline-code run. `InlineMarkdown` sets
/// `.normal` on each code span (in place of the old flat `backgroundColor`);
/// the copy-flash flips the clicked span to `.flash`. Two consumers read it:
/// `InlineCodeComposer` (to know which runs become a drawn chip) and
/// `RichTextExporter` (to keep exporting a code background).
///
/// Note this is *not* the attribute the renderer reads — a plain
/// AttributedString attribute does not propagate into `Text.Layout`. The
/// composer translates it into a `Text.customAttribute` (`InlineCodeChipMarker`),
/// which is the only channel a `TextRenderer` can see.
public enum InlineCodeChipAttribute: AttributedStringKey {
    public typealias Value = InlineCodeChipStyle
    public static let name = "marco.inlineCodeChip"
}

/// The run marker a `TextRenderer` actually reads from a `Text.Layout.Run`.
/// Attached per code segment via `Text.customAttribute(_:)` — the sole path a
/// custom attribute reaches the text layout (a range attribute on an
/// `AttributedString` does not).
struct InlineCodeChipMarker: TextAttribute, Hashable {
    var flashing: Bool = false
}

/// Builds a `Text` from a styled `AttributedString`, re-emitting each run and
/// tagging inline-code runs with `InlineCodeChipMarker` so the chip renderer
/// can find them. Used for both layers of `InlineCodeText` so their layout is
/// byte-for-byte identical and the drawn chips line up exactly with the glyphs.
enum InlineCodeComposer {
    @MainActor
    static func text(_ attributed: AttributedString) -> Text {
        var result = Text(verbatim: "")
        for run in attributed.runs {
            var segment = Text(AttributedString(attributed[run.range]))
            if let style = run[InlineCodeChipAttribute.self] {
                segment = segment.customAttribute(InlineCodeChipMarker(flashing: style == .flash))
            }
            result = result + segment
        }
        return result
    }
}

/// Draws the rounded inline-code chip fills behind marked runs — and *only*
/// the fills, never the glyphs. It runs on the non-selectable background layer
/// of `InlineCodeText`; the real text is drawn (and stays selectable) by the
/// layer stacked on top.
///
/// Per line it merges adjacent chip runs of the same flash state into one rect
/// (so one code span that the text system split into several runs reads as a
/// single chip), and a span that wraps across lines yields one rounded rect
/// per line. Rects are outset past the tight glyph bounds so the fill breathes
/// around the text instead of hugging it like the old flat highlight.
struct InlineCodeChipRenderer: TextRenderer {
    var theme: Theme

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let radius = theme.scaled(4)
        let hOutset = theme.scaled(3.5)
        let vOutset = theme.scaled(1.5)

        for line in layout {
            var groupRect: CGRect?
            var groupFlashing = false

            func flush() {
                guard let rect = groupRect else { return }
                let chip = rect.insetBy(dx: -hOutset, dy: -vOutset)
                let fill = groupFlashing ? theme.inlineCodeFlashFill : theme.inlineCodeFill
                context.fill(
                    Path(roundedRect: chip, cornerRadius: radius, style: .continuous),
                    with: .color(fill))
                groupRect = nil
            }

            for run in line {
                if let marker = run[InlineCodeChipMarker.self] {
                    let bounds = run.typographicBounds.rect
                    if let current = groupRect, groupFlashing == marker.flashing {
                        groupRect = current.union(bounds)
                    } else {
                        flush()
                        groupRect = bounds
                        groupFlashing = marker.flashing
                    }
                } else {
                    flush()
                }
            }
            flush()
        }
    }
}

/// A block's inline text, drawn so inline-code runs get rounded, padded chip
/// backgrounds while the visible text stays fully selectable and clickable
/// (link-to-copy).
///
/// SwiftUI disables a custom `TextRenderer` on any `Text` that has
/// `.textSelection(.enabled)` (verified live on macOS 26 — the renderer is
/// silently ignored, so no chip draws). We therefore can't paint the chips and
/// keep selection on a single `Text`. When the text contains inline code we
/// stack two identical `Text`s: a non-selectable background layer whose
/// `TextRenderer` paints only the chip fills (the renderer runs precisely
/// because that layer isn't selectable), and the real text on top (glyphs,
/// links, find/flash tints, selection). Both layers are built the same way so
/// they wrap identically and the fills sit exactly behind the glyphs.
///
/// Text with no inline code skips all of it and renders one plain `Text` —
/// zero extra cost on the common path.
struct InlineCodeText: View {
    let attributed: AttributedString
    let theme: Theme
    let font: Font
    var tracking: CGFloat = 0
    var lineSpacing: CGFloat = 0
    var uppercase: Bool = false
    /// The visible layer is selectable (paragraphs, headings). Table cells
    /// pass `false` to match their existing non-selectable behavior.
    var selectable: Bool = true

    private var hasChips: Bool {
        attributed.runs.contains { $0[InlineCodeChipAttribute.self] != nil }
    }

    var body: some View {
        if hasChips {
            let composed = InlineCodeComposer.text(attributed)
            ZStack(alignment: .topLeading) {
                styled(composed)
                    .textRenderer(InlineCodeChipRenderer(theme: theme))
                selecting(styled(composed))
            }
        } else {
            selecting(styled(Text(attributed)))
        }
    }

    /// Layout-affecting styling, applied identically to both layers so their
    /// wrapping matches (chip alignment depends on it).
    private func styled(_ text: Text) -> some View {
        text
            .font(font)
            .tracking(tracking)
            .lineSpacing(lineSpacing)
            .textCase(uppercase ? .uppercase : nil)
    }

    @ViewBuilder
    private func selecting(_ view: some View) -> some View {
        if selectable {
            view.textSelection(.enabled)
        } else {
            view
        }
    }
}
