import MarcoCore
import SwiftUI

/// Renders ordered / unordered / task lists from a `ListModel` built by
/// `BlockStructure` off the real cmark-gfm AST: true nested depth (each
/// level recurses into another `ListView` through `StructuredChildView`),
/// correct ordered-list start/numbering, and loose/tight item spacing —
/// rather than depth guessed from raw leading spaces. Task checkboxes are
/// interactive (PLAN §5): a click toggles the item and writes the exact
/// `- [ ]`/`- [x]` character back to disk via `checkboxToggleHandler`,
/// without entering edit mode.
struct ListView: View {
    let model: ListModel
    /// Nesting level, purely to vary the bullet glyph (•, ◦, ▪ …) the way
    /// GitHub does. Indentation itself falls out of each level's own
    /// marker + content `HStack` — no separate offset needed.
    var depth: Int = 0
    @Environment(\.theme) private var theme
    @Environment(\.checkboxBlockStartLine) private var blockStartLine
    @Environment(\.checkboxToggleHandler) private var toggleHandler
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var itemSpacing: CGFloat { theme.scaled(model.isLoose ? 12 : 4) }
    private var childSpacing: CGFloat { theme.scaled(model.isLoose ? 8 : 4) }

    var body: some View {
        VStack(alignment: .leading, spacing: itemSpacing) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: theme.scaled(8)) {
                    marker(for: item, number: model.start + index)
                    VStack(alignment: .leading, spacing: childSpacing) {
                        ForEach(item.children) { child in
                            StructuredChildView(
                                child: child,
                                textColor: textColor(for: item.checkbox),
                                listDepth: depth)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, depth == 0 ? theme.scaled(8) : 0)
    }

    private func textColor(for checkbox: TaskState?) -> Color? {
        checkbox == .checked ? theme.textSecondary : nil
    }

    @ViewBuilder
    private func marker(for item: ListModel.Item, number: Int) -> some View {
        if let checkbox = item.checkbox {
            CheckboxMarker(
                checked: checkbox == .checked,
                canToggle: blockStartLine >= 0 && item.checkboxLineOffset != nil && toggleHandler != nil,
                reduceMotion: reduceMotion
            ) {
                guard blockStartLine >= 0, let lineOffset = item.checkboxLineOffset else { return }
                toggleHandler?(blockStartLine, lineOffset, checkbox != .checked)
            }
        } else if model.isOrdered {
            Text("\(number).")
                .font(theme.bodyFont.monospacedDigit())
                .foregroundStyle(theme.textSecondary)
                .fixedSize()
                .frame(minWidth: theme.scaled(22), alignment: .trailing)
        } else {
            Text(bulletGlyph(depth: depth))
                .font(.system(size: theme.bodySize * theme.scale * bulletScale(depth)))
                .foregroundStyle(theme.textTertiary)
                .frame(width: theme.scaled(16), alignment: .center)
        }
    }

    private func bulletGlyph(depth: Int) -> String {
        switch depth % 3 {
        case 0: return "•"
        case 1: return "◦"
        default: return "▪"
        }
    }

    private func bulletScale(_ depth: Int) -> CGFloat {
        depth % 3 == 2 ? 0.7 : 1.0
    }
}

/// A single task-list checkbox glyph. Clickable when `canToggle` (the
/// owning block resolved a real line to write to and a write-back handler
/// is installed); otherwise renders identically but inertly, matching the
/// pre-M3 static appearance used by e.g. Quick Look/snapshot rendering.
private struct CheckboxMarker: View {
    let checked: Bool
    let canToggle: Bool
    let reduceMotion: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isPressed = false
    @State private var isHovering = false

    var body: some View {
        // On hover an unchecked box firms up from tertiary to secondary — a
        // slight, quiet cue that it's live — while a checked box holds its
        // accent. A faint rounded wash sits behind the glyph on hover too.
        let tint: Color = checked ? theme.accent : (isHovering ? theme.textSecondary : theme.textTertiary)
        let glyph = Image(systemName: checked ? "checkmark.square.fill" : "square")
            .font(.system(size: theme.bodySize * theme.scale, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: theme.scaled(20), alignment: .center)
            .scaleEffect(isPressed && !reduceMotion ? 0.82 : 1.0)
            .background {
                RoundedRectangle(cornerRadius: theme.scaled(5), style: .continuous)
                    .fill(theme.chipFill.opacity(isHovering ? 1 : 0))
                    .padding(theme.scaled(-1))
            }
            .contentTransition(.symbolEffect(.replace))

        if canToggle {
            Button(action: toggle) {
                glyph
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { hovering in
                if reduceMotion {
                    isHovering = hovering
                } else {
                    withAnimation(Theme.Motion.feedback) { isHovering = hovering }
                }
            }
            .help(checked ? "Mark as not done" : "Mark as done")
        } else {
            glyph
        }
    }

    private func toggle() {
        if reduceMotion {
            action()
            return
        }
        // Quiet ease-out press: a quick dip, then release as the glyph swaps
        // (symbolEffect handles the check itself). No spring — the doctrine is
        // ease-out only, no bounce.
        withAnimation(.easeOut(duration: 0.10)) { isPressed = true }
        withAnimation(.easeOut(duration: Theme.Motion.stateDuration).delay(0.06)) {
            isPressed = false
            action()
        }
    }
}
