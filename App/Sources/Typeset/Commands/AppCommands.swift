import SwiftUI

extension FocusedValues {
    /// The key window's `WindowModel`, published by `DocumentWindow`, so the
    /// real menu bar drives the focused window without per-window hidden
    /// buttons. `nil` when no document window is key.
    @Entry var windowModel: WindowModel?
}

/// The app's native menu bar (File / Edit / View / Go), driven by whichever
/// document window is frontmost (see `activeModel` — `@FocusedValue` alone is
/// unreliable here). Items enable/disable with window focus and document
/// state. Replaces M3's hidden per-window shortcut `Button`s.
struct TypesetCommands: Commands {
    @FocusedValue(\.windowModel) private var model
    @AppStorage("textScale") private var textScale: Double = 1.0

    private static let scaleStep = 0.1

    /// ⌘+/⌘− (and AppDelegate's ⌘= monitor): steps the shared text scale,
    /// clamped to 0.8–1.8.
    static func zoom(by step: Double) {
        let defaults = UserDefaults.standard
        let current = defaults.object(forKey: "textScale") as? Double ?? 1.0
        defaults.set(min(1.8, max(0.8, (current + step).roundedToPlaces(2))), forKey: "textScale")
    }

    private var hasDocument: Bool { activeModel?.controller != nil }

    // MARK: - Clipboard routing

    /// Hands an action back to the responder chain (`to: nil` makes AppKit
    /// walk it), for the cases these menu items shouldn't intercept.
    private static func forward(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }

    /// Resolve commands from the key window when SwiftUI focus is absent.
    private var activeModel: WindowModel? {
        model ?? DocumentOpener.shared.model(for: NSApp.keyWindow ?? NSApp.mainWindow)
    }

    var body: some Commands {
        // MARK: File
        CommandGroup(replacing: .newItem) {
            Button("New from Clipboard") { DocumentOpener.shared.openClipboard() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Open…") { DocumentOpener.shared.openPanel() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Open Folder…") { DocumentOpener.shared.openFolderPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            // Replacing this group also removed the standard Close item, which
            // left the app with no ⌘W at all.
            Button("Close") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: .command)
            Divider()
            Button("Save") { activeModel?.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!(activeModel?.canSave ?? false))
            Button("Save As…") { activeModel?.saveAsWithPanel() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(activeModel?.controller?.isEditing != true)
            Divider()
            Button("Export as PDF…") { activeModel?.exportPDF() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!(activeModel?.hasLoadedSource ?? false))
            Button("Export as Rich Text…") { activeModel?.exportRichText() }
                .disabled(!(activeModel?.hasLoadedSource ?? false))
            Button("Print…") { activeModel?.printDocument() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!(activeModel?.hasLoadedSource ?? false))
        }

        // MARK: Edit — clipboard
        //
        // Keep menu key equivalents while the native reader/editor owns selection.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { Self.forward(#selector(NSText.cut(_:))) }
                .keyboardShortcut("x", modifiers: .command)
            Button("Copy") { Self.forward(#selector(NSText.copy(_:))) }
                .keyboardShortcut("c", modifiers: .command)
            Button("Paste") { Self.forward(#selector(NSText.paste(_:))) }
                .keyboardShortcut("v", modifiers: .command)
            Button("Delete") { Self.forward(#selector(NSText.delete(_:))) }
            Button("Select All") { Self.forward(#selector(NSResponder.selectAll(_:))) }
                .keyboardShortcut("a", modifiers: .command)
        }

        // MARK: Edit — Find + Copy as Rich Text
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy as Rich Text") { activeModel?.copyAsRichText() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!(activeModel?.hasLoadedSource ?? false))
            Button("Copy as Quote for Agent") { activeModel?.copyQuoteForAgent() }
                .keyboardShortcut("c", modifiers: [.command, .shift, .option])
                .disabled(!hasDocument)
            Divider()
            Button("Find…") { activeModel?.openFind() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!(activeModel?.canFind ?? false))
            Button("Find Next") { activeModel?.findNext() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(!(activeModel?.canFind ?? false))
            Button("Find Previous") { activeModel?.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!(activeModel?.canFind ?? false))
        }

        // MARK: View — sidebar, edit mode, zoom, follow mode
        CommandGroup(after: .toolbar) {
            Button((activeModel?.showsOutline ?? false) ? "Hide Outline" : "Show Outline") {
                activeModel?.showsOutline.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(!hasDocument)

            Button((activeModel?.controller?.isEditing ?? false) ? "Done Editing" : "Edit Source") {
                activeModel?.toggleEditMode()
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(activeModel?.controller?.isLoading != false || activeModel?.controller?.loadError != nil)

            Divider()

            Button("Actual Size") { textScale = 1.0 }
                .keyboardShortcut("0", modifiers: .command)
            Button("Zoom In") { Self.zoom(by: Self.scaleStep) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out") { Self.zoom(by: -Self.scaleStep) }
                .keyboardShortcut("-", modifiers: .command)

            Divider()

            Button((activeModel?.controller?.followModeEnabled ?? false) ? "Turn Off Follow Mode" : "Turn On Follow Mode") {
                activeModel?.controller?.followModeEnabled.toggle()
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(!hasDocument)

            Divider()

            Button("Next Change") { activeModel?.goToNextChange() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!(activeModel?.canGoToNextChange ?? false))
            Button("Previous Change") { activeModel?.goToPreviousChange() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!(activeModel?.canGoToPreviousChange ?? false))
        }

        CommandGroup(replacing: .help) {
            if let guide = Bundle.main.url(forResource: "Welcome", withExtension: "md") {
                Button("\(Bundle.main.displayName) Guide") { DocumentOpener.shared.open(guide) }
            }
            Divider()
            Button("Privacy Policy") { NSWorkspace.shared.open(URL(string: "https://typeset.md/privacy")!) }
            Button("Support") { NSWorkspace.shared.open(URL(string: "https://typeset.md/support")!) }
            if let privacy = Bundle.main.url(forResource: "Privacy", withExtension: "md") {
                Button("Privacy Policy (Offline)") { DocumentOpener.shared.open(privacy) }
            }
            if let notices = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "md") {
                Button("Third-party Notices") { DocumentOpener.shared.open(notices) }
            }
        }

        // MARK: Go — history
        CommandMenu("Go") {
            Button("Back") { activeModel?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!(activeModel?.canGoBack ?? false))
            Button("Forward") { activeModel?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!(activeModel?.canGoForward ?? false))
            Divider()
            // ⌘K, not ⌘P: ⌘P stays Print (macOS convention).
            Button("Open Quickly…") { activeModel?.showsQuickOpen = true }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(activeModel?.quickOpenRoot == nil)
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
