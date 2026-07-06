import SwiftUI

/// Shown when an *opened* file has no content — either it was empty to
/// begin with, or a live reload observed it become empty (e.g. an agent
/// truncated it mid-rewrite). Distinct from `EmptyStateView`, which is for
/// a window with no file at all.
struct EmptyDocumentView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.plaintext")
                .font(.system(size: 30))
                .foregroundStyle(theme.textTertiary)
            Text("Empty Document")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }
}
