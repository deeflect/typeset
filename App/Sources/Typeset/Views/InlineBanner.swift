import SwiftUI
import TypesetRendering

/// Full-width 44 pt strip under the toolbar (board 08). It pushes the document
/// down instead of floating over it, and is never a modal (PLAN §4).
struct InlineBanner<Actions: View>: View {
    enum Tone { case warn, neutral }
    let tone: Tone
    let symbol: String
    let title: String
    var message: String = ""
    @ViewBuilder let actions: Actions
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tone == .warn ? theme.warn : theme.textSecondary)
                .frame(width: 16)
            Text("\(Text(title).fontWeight(.semibold)) \(Text(message).foregroundStyle(theme.textSecondary))")
                .font(.system(size: 13))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions.buttonStyle(BannerButtonStyle(stroke: tone == .warn ? theme.warnButtonStroke : theme.quoteBar))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .background(tone == .warn ? theme.warnFill : theme.sidebar)
        .overlay(alignment: .top) { stroke }
        .overlay(alignment: .bottom) { stroke }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var stroke: some View {
        Rectangle().fill(tone == .warn ? theme.warnStroke : theme.hairline).frame(height: 1)
    }
}

/// Banner action: page fill, 1 pt stroke, 26 pt tall, radius 7.
struct BannerButtonStyle: ButtonStyle {
    let stroke: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(Color(nsColor: .labelColor))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(stroke, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .fixedSize()
    }
}

/// Custom-drawn buttons (Open…, recent rows, lightbox close): dim while pressed, as system buttons do.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.75 : 1)
    }
}
