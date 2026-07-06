import SwiftUI

/// The single source of visual truth for the reading view.
///
/// A `Theme` is a lightweight value computed from the current color scheme
/// and text-size scale. Every block view reads it from the environment, so
/// the whole typographic ramp scales and recolors together. Colors lean on
/// Apple's semantic system colors (label / secondaryLabel / textBackground)
/// for a native, auto-adapting base, with a few hand-tuned tints layered on
/// top for code, quotes, and tables.
///
/// Public: shared by the app and the Quick Look extension (and the app's
/// export/print/snapshot paths), which each construct their own `Theme`
/// value and pass it through the environment.
public struct Theme: Equatable {
    public var colorScheme: ColorScheme
    /// App-wide text-size multiplier (⌘+/⌘−/⌘0), persisted via AppStorage.
    public var scale: CGFloat

    public init(colorScheme: ColorScheme, scale: CGFloat) {
        self.colorScheme = colorScheme
        self.scale = scale
    }

    private var isDark: Bool { colorScheme == .dark }

    // MARK: - Layout

    /// Reading measure cap (~70ch at body size). Prose is centered within
    /// this; code and table cards may fill it edge to edge.
    public var contentMaxWidth: CGFloat { 720 }
    public var contentHorizontalPadding: CGFloat { 48 }
    public var contentTopPadding: CGFloat { 40 }
    public var contentBottomPadding: CGFloat { 160 }

    // MARK: - Semantic colors

    public var background: Color { Color(nsColor: .textBackgroundColor) }
    public var textPrimary: Color { Color(nsColor: .labelColor) }
    public var textSecondary: Color { Color(nsColor: .secondaryLabelColor) }
    public var textTertiary: Color { Color(nsColor: .tertiaryLabelColor) }
    public var accent: Color { Color.accentColor }

    // MARK: - Surface tints (hand-tuned per appearance)

    public var codeCardFill: Color {
        isDark ? Color(red: 0.13, green: 0.13, blue: 0.145)
               : Color(red: 0.968, green: 0.968, blue: 0.972)
    }
    public var codeCardStroke: Color {
        isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.07)
    }
    /// Neutral "chip" fill for inline code — deliberately un-tinted (no
    /// accent) so a code span never reads as a text-selection highlight, the
    /// way an accent-blue fill did in dark mode. Matches how GitHub / Notes
    /// style inline code: a faint gray surface, body-colored text.
    public var inlineCodeFill: Color {
        isDark ? Color(white: 1.0, opacity: 0.11) : Color(white: 0.0, opacity: 0.055)
    }
    public var inlineCodeText: Color { textPrimary }

    public var quoteBar: Color { accent.opacity(isDark ? 0.85 : 0.75) }
    public var quoteText: Color { textSecondary }
    public var quoteFill: Color { accent.opacity(isDark ? 0.06 : 0.045) }

    public var tableStroke: Color {
        isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.09)
    }
    public var tableHeaderFill: Color {
        isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.035)
    }
    public var tableRowHoverFill: Color {
        isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.025)
    }

    public var chipFill: Color {
        isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
    }
    public var chipStroke: Color {
        isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.08)
    }

    public var thematicBreak: Color {
        isDark ? Color.white.opacity(0.22) : Color.black.opacity(0.20)
    }

    public var linkColor: Color { accent }

    // MARK: - Find highlights (⌘F)

    /// Tint under every ⌘F match. A soft, warm yellow — the platform's
    /// find-highlight idiom, tuned for each appearance so it reads on both
    /// paper-white and near-black without fighting the accent color used for
    /// links and the change-pulse.
    public var findMatchHighlight: Color {
        isDark ? Color(red: 0.62, green: 0.50, blue: 0.10).opacity(0.55)
               : Color(red: 1.0, green: 0.86, blue: 0.30).opacity(0.75)
    }
    /// Stronger tint on the *current* match (⌘G steps between them), so the
    /// active hit stands out from the rest of the field at a glance.
    public var findCurrentHighlight: Color {
        isDark ? Color(red: 0.95, green: 0.66, blue: 0.12).opacity(0.85)
               : Color(red: 1.0, green: 0.62, blue: 0.0).opacity(0.85)
    }
    /// Foreground forced on the current match so text stays legible against
    /// the saturated current-highlight fill in dark mode.
    public var findCurrentText: Color {
        isDark ? Color.black.opacity(0.92) : textPrimary
    }

    // MARK: - Spacing scale

    public func scaled(_ value: CGFloat) -> CGFloat { value * scale }

    // MARK: - Fonts

    public var bodySize: CGFloat { 15 }
    public var bodyLineSpacing: CGFloat { scaled(6.5) }

    public var bodyFont: Font { .system(size: bodySize * scale, weight: .regular) }
    /// Monospaced font for code, sized relative to a given point size so it
    /// visually matches the surrounding text (SF Mono runs a touch large).
    public func monoFont(_ size: CGFloat) -> Font {
        .system(size: size * scale, weight: .regular, design: .monospaced)
    }
    public var codeBlockFont: Font { monoFont(13) }
    public var inlineCodeSize: CGFloat { bodySize * 0.94 }

    // MARK: - Heading ramp

    public struct HeadingStyle {
        public var font: Font
        public var color: Color
        public var lineSpacing: CGFloat
        public var spacingAbove: CGFloat
        public var spacingBelow: CGFloat
        public var tracking: CGFloat
        public var uppercase: Bool
    }

    public func heading(level: Int) -> HeadingStyle {
        switch level {
        case 1:
            return HeadingStyle(
                font: .system(size: 30 * scale, weight: .bold),
                color: textPrimary, lineSpacing: scaled(2),
                spacingAbove: scaled(8), spacingBelow: scaled(12),
                tracking: -0.5, uppercase: false)
        case 2:
            return HeadingStyle(
                font: .system(size: 23 * scale, weight: .bold),
                color: textPrimary, lineSpacing: scaled(1),
                spacingAbove: scaled(30), spacingBelow: scaled(8),
                tracking: -0.3, uppercase: false)
        case 3:
            return HeadingStyle(
                font: .system(size: 18.5 * scale, weight: .semibold),
                color: textPrimary, lineSpacing: 0,
                spacingAbove: scaled(24), spacingBelow: scaled(6),
                tracking: -0.2, uppercase: false)
        case 4:
            return HeadingStyle(
                font: .system(size: 15.5 * scale, weight: .semibold),
                color: textPrimary, lineSpacing: 0,
                spacingAbove: scaled(20), spacingBelow: scaled(4),
                tracking: 0, uppercase: false)
        case 5:
            return HeadingStyle(
                font: .system(size: 13.5 * scale, weight: .semibold),
                color: textSecondary, lineSpacing: 0,
                spacingAbove: scaled(18), spacingBelow: scaled(3),
                tracking: 0, uppercase: false)
        default:
            return HeadingStyle(
                font: .system(size: 12 * scale, weight: .semibold),
                color: textTertiary, lineSpacing: 0,
                spacingAbove: scaled(16), spacingBelow: scaled(3),
                tracking: 0.7, uppercase: true)
        }
    }
}

public extension EnvironmentValues {
    @Entry var theme: Theme = Theme(colorScheme: .light, scale: 1)
}
