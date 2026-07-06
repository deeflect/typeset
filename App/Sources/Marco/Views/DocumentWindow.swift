import AppKit
import MarcoCore
import SwiftUI

/// The reading window: parses the opened file into `[Block]` and hands it to
/// the block renderer. Owns the app-wide text-size scale and derives the
/// `Theme` from the current appearance. Live reload (watching the file,
/// reparsing, diffing, applying) is delegated to `DocumentReloadController`.
///
/// M3 adds source edit mode (⌘E): a crossfade between `DocumentRenderer`
/// and `SourceEditorView`, position-preserving in both directions, plus
/// save/conflict-banner/rich-text/PDF affordances — all state for those
/// lives on `DocumentReloadController` so this view stays a thin renderer
/// of that state machine.
struct DocumentWindow: View {
    let url: URL?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("textScale") private var textScale: Double = 1.0

    @State private var controller: DocumentReloadController?
    @State private var editorHandle = SourceEditorHandle()
    @State private var pendingEditorScrollLine: Int?

    private var theme: Theme {
        Theme(colorScheme: colorScheme, scale: CGFloat(textScale))
    }

    private var syntaxColors: MarkdownSyntaxStyler.Colors {
        MarkdownSyntaxStyler.Colors(
            heading: NSColor(theme.textPrimary),
            link: NSColor(theme.linkColor),
            code: NSColor(theme.inlineCodeText),
            codeBackground: NSColor(theme.inlineCodeFill),
            dim: NSColor(theme.textTertiary))
    }

    var body: some View {
        Group {
            if let url {
                if let controller {
                    if let loadError = controller.loadError {
                        errorView(loadError)
                    } else if controller.blocks.isEmpty, !controller.isEditing {
                        EmptyDocumentView()
                    } else {
                        ZStack {
                            if controller.isEditing {
                                SourceEditorView(
                                    text: editedTextBinding(controller),
                                    colors: syntaxColors,
                                    handle: editorHandle
                                )
                                .onAppear {
                                    if let line = pendingEditorScrollLine {
                                        DispatchQueue.main.async { editorHandle.scrollToLine(line) }
                                    }
                                }
                                .transition(.opacity)
                            } else {
                                DocumentRenderer(controller: controller, documentURL: url)
                                    .transition(.opacity)
                            }
                        }
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: controller.isEditing)
                    }
                } else {
                    Color.clear
                }
            } else {
                EmptyStateView()
            }
        }
        .environment(\.theme, theme)
        .environment(\.checkboxToggleHandler) { blockStartLine, lineOffset, checked in
            controller?.toggleCheckbox(blockStartLine: blockStartLine, itemLineOffset: lineOffset, checked: checked)
        }
        .animation(.easeInOut(duration: 0.22), value: textScale)
        .overlay(alignment: .top) { banners }
        .toolbar { toolbarContent }
        .background { WindowAccessor { controller?.window = $0 } }
        .background { hiddenShortcuts }
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

    // MARK: - Banners (never modal — PLAN §4)

    @ViewBuilder
    private var banners: some View {
        if let controller {
            if controller.conflictState == .conflictPending {
                ConflictBanner(
                    onKeepMine: { controller.resolveConflictKeepMine() },
                    onTakeTheirs: { controller.resolveConflictTakeTheirs() }
                )
            } else if let saveError = controller.saveError {
                SaveErrorBanner(
                    message: saveError,
                    onSaveAs: { saveAs(controller) },
                    onDismiss: { controller.saveError = nil }
                )
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
        if let controller {
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: Binding(get: { controller.isEditing }, set: { _ in toggleEditMode(controller) })) {
                    Image(systemName: controller.isEditing ? "doc.richtext" : "pencil")
                }
                .toggleStyle(.button)
                .help(controller.isEditing ? "Done Editing (⌘E)" : "Edit Source (⌘E)")
            }
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: Binding(
                    get: { controller.followModeEnabled },
                    set: { controller.followModeEnabled = $0 }
                )) {
                    Image(systemName: "arrow.down.to.line")
                }
                .toggleStyle(.button)
                .help("Follow Mode — auto-scroll to the latest change while the file is edited on disk")
            }
        }
    }

    // MARK: - Mode transition (⌘E), position-preserving both directions

    private func toggleEditMode(_ controller: DocumentReloadController) {
        if controller.isEditing {
            let caretLine = editorHandle.caretLine()
            if let targetBlockID = controller.exitEditMode(caretLine: caretLine) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    controller.scrollPosition.scrollTo(id: targetBlockID)
                }
            }
        } else {
            pendingEditorScrollLine = controller.enterEditMode()
        }
    }

    private func editedTextBinding(_ controller: DocumentReloadController) -> Binding<String> {
        Binding(
            get: { controller.editedText },
            set: { controller.noteEditedTextChanged($0) }
        )
    }

    // MARK: - Save As… fallback (PLAN §3: only shown when a save actually failed)

    private func saveAs(_ controller: DocumentReloadController) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url?.lastPathComponent ?? "Untitled.md"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try Data(controller.editedText.utf8).write(to: destination, options: .atomic)
            controller.saveError = nil
        } catch {
            controller.saveError = "Couldn't save to \(destination.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: - Per-window keyboard shortcuts (⌘S / ⌘⇧C / ⌘⇧E / ⌘P)
    //
    // Plain `Button`s with `.keyboardShortcut`, kept visually invisible,
    // rather than app-level `Commands` + `@FocusedValue` plumbing — this
    // app has exactly one kind of window, so each window's own hidden
    // buttons already resolve to the right (key) window's controller for
    // free, with far less ceremony.

    @ViewBuilder
    private var hiddenShortcuts: some View {
        if let controller {
            Group {
                Button("Save") { controller.save() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Copy as Rich Text") {
                    RichTextExporter.copyAsRichText(blocks: controller.blocks, theme: theme, plainMarkdown: controller.currentText)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Export PDF") {
                    PDFExporter.exportPDF(blocks: controller.blocks, suggestedName: (url?.deletingPathExtension().lastPathComponent ?? "Document") + ".pdf")
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Print") {
                    PDFExporter.print(blocks: controller.blocks)
                }
                .keyboardShortcut("p", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
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
