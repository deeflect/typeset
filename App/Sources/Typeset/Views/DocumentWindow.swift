import AppKit
import TypesetCore
import TypesetRendering
import SwiftUI

/// The reading window. Owns one `WindowModel` (history, outline, ⌘F session,
/// scroll memory) which in turn holds the `DocumentReloadController` for
/// whatever file is showing. The window is a thin renderer of that state:
/// an optional outline sidebar (^⌘S) beside the reading/editor surface.
struct DocumentWindow: View {
    let url: URL?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("textScale") private var textScale: Double = 1.0

    @State private var model = WindowModel()
    @State private var copied: String?
    /// The toast's leading mark: a checkmark for copies, a live dot for file updates.
    @State private var toastIsUpdate = false
    @State private var copyToken = 0
    /// True for a minute after the file changes on disk ("Updated just now").
    @State private var freshUpdate = false

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
            // Keyed off the model, not the `WindowGroup` value, so a window
            // that opened empty can adopt a document (`DocumentOpener` hands
            // the launch window the file that was double-clicked instead of
            // opening a second window for it).
            if model.currentURL == nil {
                EmptyStateView()
                    .ignoresSafeArea()
                    .toolbar(removing: .title)
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            } else {
                NavigationSplitView(columnVisibility: Binding(
                    get: { model.showsOutline ? .all : .detailOnly },
                    set: { model.showsOutline = $0 != .detailOnly }
                )) {
                    OutlineSidebar(model: model)
                        .navigationSplitViewColumnWidth(240)
                } detail: {
                    detailContent
                        .toolbar { toolbarContent }
                        .navigationTitle(model.currentURL?.lastPathComponent ?? Bundle.main.displayName)
                        .navigationSubtitle(subtitle)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 400)
        .environment(\.theme, theme)
        .overlay {
            if let image = model.lightboxImage {
                LightboxView(image: image) { model.lightboxImage = nil }
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            // R03/R05 toast: chrome fill, hairline, radius 14, 28 tall.
            if let copied {
                HStack(spacing: 6) {
                    if toastIsUpdate {
                        Circle().fill(theme.linkColor).frame(width: 6, height: 6)
                    } else {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.linkColor)
                    }
                    Text(copied).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.textPrimary)
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(theme.chrome, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.hairline, lineWidth: 1))
                .padding(.top, 14)
                .allowsHitTesting(false)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: -10)).combined(with: .scale(scale: 0.94, anchor: .top))
                        .animation(.spring(duration: 0.45, bounce: 0.18)),
                    removal: .opacity.animation(Theme.Motion.stateExit)))
            }
        }
        .onChange(of: model.noticeID) { signalCopied(model.notice, hold: 2) }
        .onChange(of: model.controller?.changeSummaryID) {
            guard let summary = model.controller?.changeSummary, !summary.isEmpty else { return }
            signalCopied("Updated \u{00B7} " + summary, hold: 3, isUpdate: true)
        }
        .animation(reduceMotion ? nil : Theme.Motion.state, value: textScale)
        .task(id: model.controller?.lastExternalChange) {
            freshUpdate = model.controller?.lastExternalChange != nil
            try? await Task.sleep(for: .seconds(60))
            freshUpdate = false
        }
        .background { WindowAccessor {
            model.window = $0
            $0?.titlebarSeparatorStyle = model.currentURL == nil ? .none : .automatic
        } }
        .focusedValue(\.windowModel, model)
        .sheet(isPresented: $model.showsQuickOpen) { QuickOpenView(model: model) }
        .onAppear { DocumentOpener.shared.register(model) }
        .task(id: url) {
            model.setReadingTheme(theme)
            model.load(initial: url)
        }
        .onDisappear {
            DocumentOpener.shared.unregister(model)
            model.stop()
        }
        .onChange(of: theme) { _, newTheme in model.setReadingTheme(newTheme) }
        .onChange(of: model.currentURL) { _, url in
            model.window?.titlebarSeparatorStyle = url == nil ? .none : .automatic
        }
    }

    // MARK: - Detail (reading / editor + overlays)

    @ViewBuilder
    private var detailContent: some View {
        if let controller = model.controller {
            contentArea(controller)
                .safeAreaInset(edge: .top, spacing: 0) { banners(controller) }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func contentArea(_ controller: DocumentReloadController) -> some View {
        if controller.isLoading {
            ProgressView("Opening document…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError = controller.loadError {
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
                } else if let snapshot = model.readingSnapshot {
                    NativeMarkdownReadingView(
                        document: snapshot, theme: theme, controller: model.nativeReader,
                        onCheckbox: { model.toggleCheckbox(blockStartLine: $0, itemLineOffset: $1, checked: $2) },
                        onLink: { model.openReadingLink($0) },
                        onImageAccess: { folder in
                            if FolderAccessStore.shared.requestAccess(
                                defaultDirectory: folder,
                                message: "Allow \(Bundle.main.displayName) to open images in \u{201c}\(folder.lastPathComponent)\u{201d}"
                            ) != nil { model.nativeReader.retryImages() }
                        },
                        onImageOpen: { model.lightboxImage = $0 },
                        onVisibleBlock: {
                            controller.visibleBlockID = $0
                            model.trackOutline(topBlockID: $0)
                        },
                        onToggle: { model.toggle($0) },
                        onCodeCopied: { signalCopied() }
                    )
                    .transition(.opacity)
                } else {
                    ProgressView("Rendering document…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .animation(reduceMotion ? nil : Theme.Motion.state, value: controller.isEditing)
        }
    }

    /// One inline banner at a time, most urgent first (PLAN §4: never modal).
    @ViewBuilder
    private func banners(_ controller: DocumentReloadController) -> some View {
        Group {
            if controller.conflictState == .conflictPending {
                InlineBanner(tone: .warn, symbol: "exclamationmark.triangle.fill",
                             title: "\(fileName) changed on disk", message: "Your edits aren\u{2019}t saved") {
                    Button("Keep Mine") { controller.resolveConflictKeepMine() }
                    Button("Take Theirs") { controller.resolveConflictTakeTheirs() }
                }
            } else if let saveError = controller.saveError {
                InlineBanner(tone: .warn, symbol: "exclamationmark.triangle.fill", title: saveError) {
                    Button("Save As\u{2026}") { model.saveAsWithPanel() }
                    Button("Close") { controller.saveError = nil }
                }
            } else if controller.isFileRemoved, !model.removedBannerDismissed {
                InlineBanner(tone: .warn, symbol: "exclamationmark.triangle.fill",
                             title: "\(fileName) was moved or deleted",
                             message: "Showing the last version loaded") {
                    Button("Locate\u{2026}") { model.locateMovedFile() }
                    Button("Close") { model.removedBannerDismissed = true }
                }
            } else if let hint = model.accessHint {
                InlineBanner(tone: .neutral, symbol: "lock.fill", title: hint) {
                    if let action = model.accessHintAction {
                        Button(action.title) { model.grantAccessFromHint() }
                    }
                    Button("Close") { model.dismissAccessHint() }
                }
            }
        }
        .animation(reduceMotion ? nil : Theme.Motion.state, value: model.accessHint)
        .animation(reduceMotion ? nil : Theme.Motion.state, value: controller.isFileRemoved)
    }

    private var fileName: String { model.currentURL?.lastPathComponent ?? "This file" }

    /// Toolbar subtitle (boards 01, 04, 06, 08): folder — parent by default.
    private var subtitle: String {
        guard let controller = model.controller, let url = model.currentURL else { return "" }
        if controller.isFileRemoved { return "Not on disk" }
        if controller.isEditing {
            return controller.conflictState == .clean ? "Editing \u{b7} \u{2318}E to preview" : "Edited \u{b7} \u{2318}E to preview"
        }
        let status: String
        if freshUpdate {
            status = "Updated just now"
        } else if let changes = model.changesSummary {
            status = changes
        } else {
            let folder = url.deletingLastPathComponent()
            let parent = folder.deletingLastPathComponent().lastPathComponent
            status = parent.isEmpty || parent == "/" ? folder.lastPathComponent : "\(folder.lastPathComponent) \u{2014} \(parent)"
        }
        return [status, model.taskSummary].compactMap { $0 }.joined(separator: " \u{b7} ")
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!model.canGoBack)
                .help("Back (\u{2318}[)")
            Button { model.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!model.canGoForward)
                .help("Forward (\u{2318}])")
        }
        if let controller = model.controller {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.openFind() } label: { Image(systemName: "magnifyingglass") }
                    .help("Find (\u{2318}F)")
                    .accessibilityLabel("Find")
                    .disabled(!model.canFind)
                Toggle(isOn: Binding(get: { controller.isEditing }, set: { _ in model.toggleEditMode() })) {
                    Image(systemName: "pencil")
                }
                .toggleStyle(.button)
                .disabled(controller.isLoading || controller.loadError != nil)
                .help(controller.isEditing ? "Done Editing (\u{2318}E)" : "Edit Source (\u{2318}E)")
                .accessibilityLabel("Edit Source")
                ShareLink(item: controller.url) { Image(systemName: "square.and.arrow.up") }
                    .help("Share")
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

    private func signalCopied(_ text: String = "Copied", hold: Double = 1, isUpdate: Bool = false) {
        copyToken &+= 1
        let token = copyToken
        toastIsUpdate = isUpdate
        withAnimation(reduceMotion ? nil : Theme.Motion.state) { copied = text }
        Task {
            try? await Task.sleep(for: .seconds(hold))
            if copyToken == token { withAnimation { copied = nil } }
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
                .frame(maxWidth: 520) // board 15
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }
}
