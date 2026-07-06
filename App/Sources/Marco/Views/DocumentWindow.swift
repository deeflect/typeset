import AppKit
import MarcoCore
import SwiftUI

/// The reading window. Owns one `WindowModel` (history, outline sidebar, ⌘F
/// session, scroll memory) which in turn holds the `DocumentReloadController`
/// for whatever file is showing. The window itself is a thin renderer of that
/// state: a `NavigationSplitView` with the native floating-glass outline
/// column leading and the reading/editor surface trailing.
struct DocumentWindow: View {
    let url: URL?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("textScale") private var textScale: Double = 1.0

    @State private var model = WindowModel()

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

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { model.sidebarVisible ? .all : .detailOnly },
            set: { model.sidebarVisible = ($0 != .detailOnly) })
    }

    var body: some View {
        Group {
            if url == nil {
                EmptyStateView()
            } else {
                NavigationSplitView(columnVisibility: sidebarVisibility) {
                    OutlineSidebar(model: model)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
                } detail: {
                    detailContent
                }
            }
        }
        .environment(\.theme, theme)
        .environment(\.checkboxToggleHandler) { blockStartLine, lineOffset, checked in
            model.controller?.toggleCheckbox(blockStartLine: blockStartLine, itemLineOffset: lineOffset, checked: checked)
        }
        .animation(.easeInOut(duration: 0.22), value: textScale)
        .toolbar { toolbarContent }
        .background { WindowAccessor { model.window = $0 } }
        .focusedValue(\.windowModel, model)
        .task(id: url) {
            model.readingTheme = theme
            model.load(initial: url)
        }
        .onDisappear { model.stop() }
        .onChange(of: colorScheme) { _, _ in InlineMarkdown.invalidate() }
        .onChange(of: theme) { _, newTheme in model.readingTheme = newTheme }
    }

    // MARK: - Detail (reading / editor + overlays)

    @ViewBuilder
    private var detailContent: some View {
        if let controller = model.controller {
            contentArea(controller)
                .overlay(alignment: .top) { topOverlays(controller) }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func contentArea(_ controller: DocumentReloadController) -> some View {
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
                        handle: model.editorHandle
                    )
                    .onAppear {
                        if let line = model.pendingEditorScrollLine {
                            DispatchQueue.main.async { model.editorHandle.scrollToLine(line) }
                        }
                    }
                    .transition(.opacity)
                } else {
                    DocumentRenderer(controller: controller, model: model, documentURL: model.currentURL)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: controller.isEditing)
        }
    }

    /// Find bar, conflict/save banners, and the quiet link-access hint —
    /// stacked just under the toolbar, never modal (PLAN §4).
    @ViewBuilder
    private func topOverlays(_ controller: DocumentReloadController) -> some View {
        VStack(spacing: 8) {
            if model.find.isActive {
                FindBar(model: model)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            banners(controller)
            if let hint = model.accessHint {
                AccessHintBanner(
                    message: hint,
                    actionTitle: model.accessHintAction?.title,
                    onAction: model.accessHintAction == nil ? nil : { model.grantAccessFromHint() },
                    onDismiss: { model.dismissAccessHint() }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 8)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.find.isActive)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.accessHint)
    }

    @ViewBuilder
    private func banners(_ controller: DocumentReloadController) -> some View {
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.history.count > 1 {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.goBack() } label: { Image(systemName: "chevron.backward") }
                    .disabled(!model.canGoBack)
                    .help("Back (⌘[)")
                Button { model.goForward() } label: { Image(systemName: "chevron.forward") }
                    .disabled(!model.canGoForward)
                    .help("Forward (⌘])")
            }
        }
        ToolbarItem(placement: .principal) {
            HStack(spacing: 6) {
                Text(model.currentURL?.lastPathComponent ?? Bundle.main.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.controller?.isFileRemoved == true {
                    Text("· File Removed")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        if let controller = model.controller {
            ToolbarItem(placement: .automatic) {
                Button {
                    model.find.isActive ? model.closeFind() : model.openFind()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Find (⌘F)")
            }
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: Binding(get: { controller.isEditing }, set: { _ in model.toggleEditMode() })) {
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

    // MARK: - Helpers

    private func editedTextBinding(_ controller: DocumentReloadController) -> Binding<String> {
        Binding(
            get: { controller.editedText },
            set: { controller.noteEditedTextChanged($0) }
        )
    }

    private func saveAs(_ controller: DocumentReloadController) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = model.currentURL?.lastPathComponent ?? "Untitled.md"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try Data(controller.editedText.utf8).write(to: destination, options: .atomic)
            controller.saveError = nil
        } catch {
            controller.saveError = "Couldn't save to \(destination.lastPathComponent): \(error.localizedDescription)"
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
    /// Never hardcode the app name in UI strings — read it from the bundle so
    /// renaming stays a single xcconfig edit.
    var displayName: String {
        (object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Untitled"
    }
}
