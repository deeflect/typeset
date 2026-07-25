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
struct MarcoCommands: Commands {
    @FocusedValue(\.windowModel) private var model
    @AppStorage("textScale") private var textScale: Double = 1.0
    #if DEBUG
    @AppStorage("debugTextKitReading") private var debugTextKitReading = false
    #endif

    /// Bridged from `AppDelegate` (AppKit open panel) since Open is app-level,
    /// not window-level.
    let openPanel: () -> Void

    private let minScale = 0.8
    private let maxScale = 1.8
    private let scaleStep = 0.1

    private var hasDocument: Bool { activeModel?.controller != nil }
    private var hasMatches: Bool { (activeModel?.find.matchCount ?? 0) > 0 }

    // MARK: - Clipboard routing

    /// Hands an action back to the responder chain (`to: nil` makes AppKit
    /// walk it), for the cases these menu items shouldn't intercept.
    private static func forward(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }

    /// True when a real text-editing responder is focused — the ⌘E source
    /// editor, or the field editor behind the ⌘F search field. Both are
    /// `NSTextView`s; a selectable SwiftUI `Text` is not (with one focused,
    /// the first responder is the window itself), which is what lets us tell
    /// "the user is typing" apart from "the user is reading".
    private var isEditingText: Bool {
        NSApp.keyWindow?.firstResponder is NSTextView
    }

    /// The window these clipboard actions apply to.
    ///
    /// Resolved from the key window rather than `@FocusedValue`. `focusedValue`
    /// only publishes while some view in the subtree holds SwiftUI focus, and
    /// the reading view is a plain non-focusable `ScrollView` — so `model` is
    /// routinely nil here even with a document plainly in front of the user.
    /// That is what made ⌘A keep falling through to SwiftUI's per-block
    /// selection and copy a single paragraph.
    private var activeModel: WindowModel? {
        model ?? DocumentOpener.shared.model(for: NSApp.keyWindow ?? NSApp.mainWindow)
    }

    private func selectAll() {
        guard !isEditingText, let target = activeModel, target.canSelectAllDocument else {
            Self.forward(#selector(NSResponder.selectAll(_:)))
            return
        }
        target.selectAllDocument()
    }

    private func copy() {
        // Whole document only when ⌘A claimed it. A drag-selection inside one
        // paragraph still copies just that paragraph, via SwiftUI.
        guard !isEditingText, let target = activeModel, target.isSelectAllActive else {
            Self.forward(#selector(NSText.copy(_:)))
            return
        }
        target.copySelection()
    }

    var body: some Commands {
        // MARK: File
        CommandGroup(replacing: .newItem) {
            Button("Open…") { openPanel() }
                .keyboardShortcut("o", modifiers: .command)
        }
        CommandGroup(replacing: .saveItem) {
            // Replacing this group also removed the standard Close item, which
            // left the app with no ⌘W at all.
            Button("Close") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: .command)
            Divider()
            Button("Save") { activeModel?.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!hasDocument)
            Divider()
            Button("Export as PDF…") { activeModel?.exportPDF() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!hasDocument)
            Button("Print…") { activeModel?.printDocument() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!hasDocument)
        }

        // MARK: Edit — clipboard
        //
        // These replace SwiftUI's standard pasteboard items so ⌘A / ⌘C are
        // *menu* key equivalents, which AppKit matches before the responder
        // chain runs. That ordering is the whole point: the reading view is
        // per-block `Text` with `.textSelection(.enabled)`, and once any
        // paragraph has focus SwiftUI's own selection responder answers ⌘A
        // first — so "select all" only ever grabbed the one block under the
        // caret. Owning the key equivalent makes ⌘A mean the whole document,
        // every time.
        //
        // Cut/Paste/Delete, and Copy when the document isn't wholly selected,
        // forward straight back into the responder chain, so the ⌘E source
        // editor, the ⌘F field, and dragging out a single paragraph all keep
        // their normal behaviour.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { Self.forward(#selector(NSText.cut(_:))) }
                .keyboardShortcut("x", modifiers: .command)
            Button("Copy") { copy() }
                .keyboardShortcut("c", modifiers: .command)
            Button("Paste") { Self.forward(#selector(NSText.paste(_:))) }
                .keyboardShortcut("v", modifiers: .command)
            Button("Delete") { Self.forward(#selector(NSText.delete(_:))) }
            Button("Select All") { selectAll() }
                .keyboardShortcut("a", modifiers: .command)
        }

        // MARK: Edit — Find + Copy as Rich Text
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy as Rich Text") { activeModel?.copyAsRichText() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!hasDocument)
            Divider()
            Button("Find…") { activeModel?.openFind() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!hasDocument)
            Button("Find Next") { activeModel?.findNext() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(!hasMatches)
            Button("Find Previous") { activeModel?.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!hasMatches)
        }

        // MARK: View — sidebar, edit mode, zoom, follow mode
        CommandGroup(after: .toolbar) {
            Button("Outline") {
                activeModel?.showOutlineMenu()
            }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(!(activeModel?.hasOutline ?? false))

            Button((activeModel?.controller?.isEditing ?? false) ? "Done Editing" : "Edit Source") {
                activeModel?.toggleEditMode()
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

            Button((activeModel?.controller?.followModeEnabled ?? false) ? "Turn Off Follow Mode" : "Turn On Follow Mode") {
                activeModel?.controller?.followModeEnabled.toggle()
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(!hasDocument)
        }

        // MARK: Go — history
        CommandMenu("Go") {
            Button("Back") { activeModel?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!(activeModel?.canGoBack ?? false))
            Button("Forward") { activeModel?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!(activeModel?.canGoForward ?? false))
        }

        #if DEBUG
        // MARK: Debug — M6 TextKit 2 reading surface (Phase 1, slice 1)
        CommandMenu("Debug") {
            Toggle("TextKit 2 Reading Surface", isOn: $debugTextKitReading)
                .keyboardShortcut("t", modifiers: [.command, .control])
        }
        #endif
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
