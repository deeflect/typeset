import MarcoCore
import SwiftUI

/// The reading window: parses the opened file into `[Block]` and hands it to
/// the block renderer. Owns the app-wide text-size scale and derives the
/// `Theme` from the current appearance. Live reload (watching the file,
/// reparsing, diffing, applying) is delegated to `DocumentReloadController`.
struct DocumentWindow: View {
    let url: URL?

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("textScale") private var textScale: Double = 1.0

    @State private var controller: DocumentReloadController?

    private var theme: Theme {
        Theme(colorScheme: colorScheme, scale: CGFloat(textScale))
    }

    var body: some View {
        Group {
            if let url {
                if let controller {
                    if let loadError = controller.loadError {
                        errorView(loadError)
                    } else if controller.blocks.isEmpty {
                        EmptyDocumentView()
                    } else {
                        DocumentRenderer(controller: controller, documentURL: url)
                    }
                } else {
                    Color.clear
                }
            } else {
                EmptyStateView()
            }
        }
        .environment(\.theme, theme)
        .animation(.easeInOut(duration: 0.22), value: textScale)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Text(url?.lastPathComponent ?? Bundle.main.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if controller?.isFileRemoved == true {
                        Text("· File Removed")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if url != nil {
                ToolbarItem(placement: .automatic) {
                    Toggle(isOn: Binding(
                        get: { controller?.followModeEnabled ?? false },
                        set: { controller?.followModeEnabled = $0 }
                    )) {
                        Image(systemName: "arrow.down.to.line")
                    }
                    .toggleStyle(.button)
                    .help("Follow Mode — auto-scroll to the latest change while the file is edited on disk")
                }
            }
        }
        .task(id: url) {
            guard let url else { return }
            let newController = DocumentReloadController(url: url)
            controller = newController
            newController.start()
        }
        .onDisappear {
            controller?.stop()
        }
        .onChange(of: colorScheme) { _, _ in
            InlineMarkdown.invalidate()
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }
}

extension Bundle {
    /// Never hardcode the app name in UI strings — read it from the
    /// bundle so renaming stays a single xcconfig edit.
    var displayName: String {
        (object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Untitled"
    }
}
