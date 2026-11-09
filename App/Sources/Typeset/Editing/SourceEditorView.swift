import AppKit
import SwiftUI

/// Plain, fast source-mode caret/scroll handle exposed to `DocumentWindow`
/// so it can ask "what line is the caret on" (source → reading position
/// preservation) and "scroll to this line" (reading → source), without
/// SwiftUI needing a direct reference to the underlying `NSTextView`.
@MainActor
final class SourceEditorHandle {
    fileprivate weak var textView: NSTextView?
    private var pendingFind: NSTextFinder.Action?

    func find(_ action: NSTextFinder.Action) {
        guard textView != nil else { pendingFind = action; return }
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView?.performFindPanelAction(item)
    }

    fileprivate func flushPendingFind() {
        guard let pendingFind else { return }
        self.pendingFind = nil
        find(pendingFind)
    }

    /// 0-based line the caret currently sits on (counting newlines before
    /// the selection start), or `nil` if the editor isn't mounted yet.
    func caretLine() -> Int? {
        guard let textView else { return nil }
        let location = textView.selectedRange().location
        let text = textView.string as NSString
        guard location <= text.length else { return nil }
        var line = 0
        text.enumerateSubstrings(in: NSRange(location: 0, length: min(location, text.length)), options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            line += 1
        }
        return line
    }

    /// The selected source text and its 1-based file lines, or `nil` with no selection.
    func selection() -> (text: String, lines: ClosedRange<Int>)? {
        guard let textView, textView.selectedRange().length > 0 else { return nil }
        let text = textView.string as NSString
        let range = textView.selectedRange()
        return (text.substring(with: range), AgentQuote.lines(in: text, range: range))
    }

    /// Scrolls so `line` (0-based) is visible at the top of the editor and
    /// places the caret there.
    func scrollToLine(_ line: Int) {
        guard let textView else { return }
        let text = textView.string as NSString
        var currentLine = 0
        var targetLocation = 0
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, lineRange, _, stop in
            if currentLine == line {
                targetLocation = lineRange.location
                stop.pointee = true
            }
            currentLine += 1
        }
        let range = NSRange(location: targetLocation, length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }
}

/// Wraps a plain `NSTextView` explicitly on the TextKit 1 path (its own
/// `NSLayoutManager`, never a `NSTextLayoutManager`, so TextKit 2 can't
/// activate — PLAN §4/§8: NSTextView on TextKit 1 is the FINAL decision,
/// benchmarked against STTextView/TextKit 2 and found ~1000x faster on
/// large files). SF Mono 13.5/22, wrapping, no line numbers/minimap. System
/// spellcheck/dictation/IME are left at their NSTextView defaults.
struct SourceEditorView: NSViewRepresentable {
    @Binding var text: String
    let colors: MarkdownSyntaxStyler.Colors
    let handle: SourceEditorHandle

    // `nonisolated(unsafe)`: an immutable shared constant referenced from the
    // nonisolated `NSTextStorageDelegate` callback (incremental styling). NSFont
    // isn't Sendable, but this value is never mutated after init, so the
    // cross-actor read is safe.
    nonisolated(unsafe) static let font = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)

    func makeNSView(context: Context) -> NSScrollView {
        // Building the TextKit stack by hand (rather than
        // `NSTextView(frame:)`, which on recent SDKs may default to a
        // TextKit 2 `NSTextLayoutManager`) is what guarantees TextKit 1.
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        let textContainer = NSTextContainer(containerSize: containerSize)
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = MeasuredTextView(frame: .zero, textContainer: textContainer)
        textView.isRichText = false
        textView.usesFindBar = true
        textView.font = Self.font
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        // Without an explicit min/max, a vertically-resizable NSTextView built
        // by hand keeps its `.zero` frame height as its max, so the document
        // view never grows past the clip view and there's nothing to scroll
        // (P0). Let it grow unbounded vertically.
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [NSView.AutoresizingMask.width]
        textView.delegate = context.coordinator
        textStorage.delegate = context.coordinator
        textView.string = text
        context.coordinator.syncedText = text

        handle.textView = textView
        DispatchQueue.main.async { [weak handle] in handle?.flushPendingFind() }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.drawsBackground = false

        // ⌘E should land the caret in the editor ready to type. The window
        // isn't resolved yet at make-time, so defer first-responder to the
        // next runloop turn once the view is in a window.
        DispatchQueue.main.async { [weak textView] in
            guard let textView, let window = textView.window else { return }
            window.makeFirstResponder(textView)
        }

        MarkdownSyntaxStyler.styleFullDocument(textStorage, baseFont: Self.font, colors: colors)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        // Compared against the last text we exchanged with the binding, not
        // `textView.string` (which bridges a full copy on every update).
        if text != context.coordinator.syncedText {
            // External change (e.g. a silent watcher reload while clean) —
            // replace the buffer and restyle the whole document, since this
            // isn't a local edit the incremental path can target. Undo
            // history described the old buffer; replaying it here would
            // corrupt the new one.
            textView.string = text
            context.coordinator.syncedText = text
            textView.undoManager?.removeAllActions()
            if let storage = textView.textStorage {
                MarkdownSyntaxStyler.styleFullDocument(storage, baseFont: Self.font, colors: colors)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: SourceEditorView
        var syncedText = ""

        init(parent: SourceEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let text = textView.string
            syncedText = text
            parent.text = text
        }

        // Incremental styling: style only the edited paragraph range so
        // typing never waits on a whole-document restyle (PLAN §1: "must
        // stay instant on typical files").
        func textStorage(
            _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange, changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            MarkdownSyntaxStyler.styleEdited(textStorage, editedRange: editedRange, baseFont: SourceEditorView.font, colors: parent.colors)
        }
    }
}

/// Board 06: raw Markdown on the same 680 pt measure as the reader, with
/// 28 pt minimum gutters once the window is narrower.
final class MeasuredTextView: NSTextView {
    override func setFrameSize(_ newSize: NSSize) {
        let inset = NSSize(width: max(28, (newSize.width - 680) / 2), height: 64)
        if textContainerInset != inset { textContainerInset = inset }
        super.setFrameSize(newSize)
    }
}
