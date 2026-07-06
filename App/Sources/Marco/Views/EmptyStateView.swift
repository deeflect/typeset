import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shown in a window that was opened without a file (plain ⌘N-style
/// launch). A single centered glass card: drop target + Open button.
struct EmptyStateView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var isTargeted = false

    private var appDelegate: AppDelegate? {
        NSApp.delegate as? AppDelegate
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text(Bundle.main.displayName)
                .font(.title2.bold())

            Text("Drop a Markdown file here, or")
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Open…") {
                    appDelegate?.openPanel()
                }
                .keyboardShortcut(.defaultAction)

                if let welcome = Bundle.main.url(forResource: "Welcome", withExtension: "md") {
                    Button("Read the Guide") {
                        openWindow(value: Optional(welcome))
                    }
                }
            }
        }
        .padding(40)
        .glassEffect(in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(isTargeted ? Color.accentColor : .clear, lineWidth: 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { ["md", "markdown", "mdown"].contains($0.pathExtension.lowercased()) }) else {
                return false
            }
            openWindow(value: Optional(url))
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
}
