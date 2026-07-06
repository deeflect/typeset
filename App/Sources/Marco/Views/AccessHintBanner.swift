import SwiftUI

/// A quiet, non-modal hint (PLAN §4: never a modal) shown when a relative
/// link points at a file outside the sandbox scope the user granted. Auto-
/// dismisses; also dismissable by hand.
struct AccessHintBanner: View {
    let message: String
    var actionTitle: String? = nil
    var onAction: (() -> Void)? = nil
    let onDismiss: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.slash")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 13))
                .lineLimit(2)
            Spacer()
            if let actionTitle, let onAction {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.borderedProminent)
            }
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.chipStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal, 16)
    }
}
