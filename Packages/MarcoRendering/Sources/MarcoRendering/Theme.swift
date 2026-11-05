import SwiftUI

/// The single source of visual truth for the reading view.
///
/// A `Theme` is a lightweight value computed from the current color scheme
/// and text-size scale. The native document builder and app chrome share it.
/// Colors lean on
/// Apple's semantic system colors (label / secondaryLabel / textBackground)
/// for a native, auto-adapting base, with a few hand-tuned tints layered on
/// top for code, quotes, and tables.
///
/// Public: shared by the app and the Quick Look extension (and the app's
/// export/print/snapshot paths), which each construct their own `Theme`
/// value and pass it through the environment.
public struct Theme: Equatable, Sendable {
    public var colorScheme: ColorScheme
    /// App-wide text-size multiplier (⌘+/⌘−/⌘0), persisted via AppStorage.
    public var scale: CGFloat

    public init(colorScheme: ColorScheme, scale: CGFloat) {
        self.colorScheme = colorScheme
        self.scale = scale
    }

    private var isDark: Bool { colorScheme == .dark }

    // MARK: - Layout (Paper "Marco · Redesign" tokens)

    /// Reading measure. Prose, code cards and tables share it.
    public var contentMaxWidth: CGFloat { 680 }
    /// Minimum side gutter once the window is narrower than the measure (board 09).
    public var contentHorizontalPadding: CGFloat { 28 }
    public var contentTopPadding: CGFloat { 40 }

    // MARK: - Semantic colors

    public var background: Color { Color(nsColor: .textBackgroundColor) }
    public var textPrimary: Color { Color(nsColor: .labelColor) }
    public var textSecondary: Color { Color(nsColor: .secondaryLabelColor) }
    public var textTertiary: Color { Color(nsColor: .tertiaryLabelColor) }
    public var accent: Color { Color.accentColor }
    public var linkColor: Color { accent }

    /// Board `hairline`: #E3E3E6 / #3A3A3C.
    public var hairline: Color { isDark ? Color(hex: 0x3A3A3C) : Color(hex: 0xE3E3E6) }
    /// Board `fill`: code cards and the blocked-image card. #F2F2F4 / #2C2C2E.
    public var codeCardFill: Color { isDark ? Color(hex: 0x2C2C2E) : Color(hex: 0xF2F2F4) }
    /// Neutral chip under inline code, never accent-tinted so it can't read as selection.
    public var inlineCodeFill: Color {
        isDark ? Color(white: 1.0, opacity: 0.11) : Color(white: 0.0, opacity: 0.055)
    }
    public var inlineCodeText: Color { textPrimary }
    /// Quote bar and table header rule: system gray 4 (#D1D1D6 light).
    public var quoteBar: Color { Color(nsColor: .systemGray4) }
    public var tableHeaderRule: Color { quoteBar }
    public var tableStroke: Color { hairline }

    /// Moved/deleted banner (board 08).
    public var warn: Color { isDark ? Color(hex: 0xFFB340) : Color(hex: 0xB25E00) }
    public var warnFill: Color { isDark ? Color(hex: 0x3A2E1A) : Color(hex: 0xFFF6E5) }
    public var warnStroke: Color { isDark ? Color(hex: 0x5A4524) : Color(hex: 0xF0DDB8) }
    public var warnButtonStroke: Color { isDark ? Color(hex: 0x6B5530) : Color(hex: 0xE6D3AE) }

    // MARK: - Type

    public func scaled(_ value: CGFloat) -> CGFloat { value * scale }
    /// Body 16 / 26.
    public var bodySize: CGFloat { 16 }
    public var bodyLineHeight: CGFloat { 26 }
    public var inlineCodeSize: CGFloat { bodySize * 0.94 }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

public extension Theme {
    /// The app's motion vocabulary (product register): motion conveys state,
    /// never decoration. Ease-out only — no bounce/elastic. Feedback is
    /// instant (~120ms); state changes are 200–300ms; exits run ~75% of their
    /// entry so dismissals feel quicker than arrivals. Every animated call
    /// site pairs these with a Reduce Motion branch (snap, no fade).
    enum Motion {
        /// Instant acknowledgment: hover/press tints, focus, button feedback.
        public static let feedbackDuration: Double = 0.12
        /// State change: crossfades, banner/find-bar enter, follow reveal.
        public static let stateDuration: Double = 0.22
        /// Exit: ~75% of `stateDuration` so dismissals feel quicker.
        public static let exitDuration: Double = 0.16
        public static let feedback: Animation = .easeOut(duration: feedbackDuration)
        public static let state: Animation = .easeOut(duration: stateDuration)
        public static let stateExit: Animation = .easeOut(duration: exitDuration)
    }
}

public extension EnvironmentValues {
    @Entry var theme: Theme = Theme(colorScheme: .light, scale: 1)
}
