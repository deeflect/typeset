import AppKit
import SwiftUI

/// Plain, fast source-mode caret/scroll handle exposed to `DocumentWindow`
/// so it can ask "what line is the caret on" (source → reading position
/// preservation) and "scroll to this line" (reading → source), without
/// SwiftUI needing a direct reference to the underlying `NSTextView`.
@MainActor
final class SourceEditorHandle {
    fileprivate weak var textView: NSTextView?

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
/// large files). SF Mono 13, wrapping, no line numbers/minimap. System
/// spellcheck/dictation/IME are left at their NSTextView defaults.
struct SourceEditorView: NSViewRepresentable {
    @Binding var text: String
    let colors: MarkdownSyntaxStyler.Colors
    let handle: SourceEditorHandle

    // `nonisolated(unsafe)`: an immutable shared constant referenced from the
    // nonisolated `NSTextStorageDelegate` callback (incremental styling). NSFont
    // isn't Sendable, but this value is never mutated after init, so the
    // cross-actor read is safe.
    nonisolated(unsafe) static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

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

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isRichText = false
        textView.font = Self.font
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [NSView.AutoresizingMask.width]
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.delegate = context.coordinator
        textStorage.delegate = context.coordinator
        textView.string = text

        handle.textView = textView

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.drawsBackground = false

        MarkdownSyntaxStyler.styleFullDocument(textStorage, baseFont: Self.font, colors: colors)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if textView.string != text {
            // External change (e.g. a silent watcher reload while clean) —
            // replace the buffer and restyle the whole document, since this
            // isn't a local edit the incremental path can target.
            textView.string = text
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

        init(parent: SourceEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
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
