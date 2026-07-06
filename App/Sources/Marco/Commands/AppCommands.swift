import SwiftUI

extension FocusedValues {
    /// The key window's `WindowModel`, published by `DocumentWindow`, so the
    /// real menu bar drives the focused window without per-window hidden
    /// buttons. `nil` when no document window is key.
    @Entry var windowModel: WindowModel?
}

/// The app's native menu bar (File / Edit / View / Go), wired to the focused
/// window via `@FocusedValue`. Items enable/disable with window focus and
/// document state. Replaces M3's hidden per-window shortcut `Button`s.
struct MarcoCommands: Commands {
    @FocusedValue(\.windowModel) private var model
    @AppStorage("textScale") private var textScale: Double = 1.0

    /// Bridged from `AppDelegate` (AppKit open panel) since Open is app-level,
    /// not window-level.
    let openPanel: () -> Void

    private let minScale = 0.8
    private let maxScale = 1.8
    private let scaleStep = 0.1

    private var hasDocument: Bool { model?.controller != nil }
    private var hasMatches: Bool { (model?.find.matchCount ?? 0) > 0 }

    var body: some Commands {
        // MARK: File
        CommandGroup(replacing: .newItem) {
            Button("Open…") { openPanel() }
                .keyboardShortcut("o", modifiers: .command)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model?.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!hasDocument)
            Divider()
            Button("Export as PDF…") { model?.exportPDF() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!hasDocument)
            Button("Print…") { model?.printDocument() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!hasDocument)
        }

        // MARK: Edit — Find + Copy as Rich Text
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy as Rich Text") { model?.copyAsRichText() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!hasDocument)
            Divider()
            Button("Find…") { model?.openFind() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!hasDocument)
            Button("Find Next") { model?.findNext() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(!hasMatches)
            Button("Find Previous") { model?.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!hasMatches)
        }

        // MARK: View — sidebar, edit mode, zoom, follow mode
        CommandGroup(after: .toolbar) {
            Button((model?.sidebarVisible ?? false) ? "Hide Outline" : "Show Outline") {
                model?.toggleSidebar()
            }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(!hasDocument)

            Button((model?.controller?.isEditing ?? false) ? "Done Editing" : "Edit Source") {
                model?.toggleEditMode()
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!hasDocument)

            Divider()

            Button("Actual Size") { textScale = 1.0 }
                .keyboardShortcut("0", modifiers: .command)
            Button("Zoom In") {
                textScale = min(maxScale, (textScale + scaleStep).roundedToPlaces(2))
            }
            .keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out") {
                textScale = max(minScale, (textScale - scaleStep).roundedToPlaces(2))
            }
            .keyboardShortcut("-", modifiers: .command)

            Divider()

            Button((model?.controller?.followModeEnabled ?? false) ? "Turn Off Follow Mode" : "Turn On Follow Mode") {
                model?.controller?.followModeEnabled.toggle()
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(!hasDocument)
        }

        // MARK: Go — history
        CommandMenu("Go") {
            Button("Back") { model?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!(model?.canGoBack ?? false))
            Button("Forward") { model?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!(model?.canGoForward ?? false))
        }
    }
}

private extension Double {
    /// Rounds to a fixed number of decimals so accumulated ⌘+/⌘− steps don't
    /// drift into values like 1.2000000000000002.
    func roundedToPlaces(_ places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
