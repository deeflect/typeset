import SwiftUI

/// PLAN §4's non-modal conflict banner: shown inside the window's top edge
/// when the watcher reports the file changed on disk while the source
/// editor has unsaved changes. Never a modal dialog.
struct ConflictBanner: View {
    let onKeepMine: () -> Void
    let onTakeTheirs: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            Text("File changed on disk")
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Button("Keep Mine", action: onKeepMine)
                .buttonStyle(.bordered)
            Button("Take Theirs", action: onTakeTheirs)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.chipStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.top, 8)
        .padding(.horizontal, 16)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// PLAN §3's save-failure fallback: a non-modal banner (never a modal
/// dialog) offering Save As… when an autosave/⌘S write fails (no write
/// access, volume gone, etc.).
struct SaveErrorBanner: View {
    let message: String
    let onSaveAs: () -> Void
    let onDismiss: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 13))
                .lineLimit(2)
            Spacer()
            Button("Save As…", action: onSaveAs)
                .buttonStyle(.borderedProminent)
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.chipStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.top, 8)
        .padding(.horizontal, 16)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
