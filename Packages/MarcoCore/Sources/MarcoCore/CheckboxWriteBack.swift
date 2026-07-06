import Foundation

/// Pure logic for flipping a single task-list checkbox character in the raw
/// file text, used by the reading view's clickable checkboxes (PLAN §6) to
/// write `- [ ]` / `- [x]` back to disk without entering edit mode.
///
/// Callers locate the line with `Block.startLine` (the owning list block's
/// start, body-relative) plus the item's own line offset within that
/// block's `rawText` (`ListModel.Item.checkboxLineOffset`, itself relative
/// to the block, so `blockStartLine + itemLineOffset` is the absolute
/// body-relative line). `flip` re-derives frontmatter/body itself so the
/// caller never has to think about the frontmatter offset.
public enum CheckboxWriteBack {

    /// Attempts to flip the checkbox at `blockStartLine + itemLineOffset`
    /// in `fileText` (the full, current on-disk content) to `checked`.
    ///
    /// This is the verify-before-write guard: it only succeeds if the
    /// resolved line still looks like a task-list item marker currently in
    /// the OPPOSITE state. If the file changed under us since the click was
    /// registered — different content, a shifted line, an already-flipped
    /// box, or a line that no longer looks like a checkbox at all — this
    /// returns `nil` so the caller can fall back to a normal reload instead
    /// of writing blind.
    public static func flip(fileText: String, blockStartLine: Int, itemLineOffset: Int, checked: Bool) -> String? {
        guard blockStartLine >= 0, itemLineOffset >= 0 else { return nil }

        let normalized = MarkdownParser.normalizingLineEndings(fileText)
        let (frontmatter, body) = MarkdownParser.splitFrontmatter(normalized)
        var bodyLines = body.components(separatedBy: "\n")
        let lineIndex = blockStartLine + itemLineOffset
        guard lineIndex >= 0, lineIndex < bodyLines.count else { return nil }
        guard let newLine = flippedLine(bodyLines[lineIndex], checked: checked) else { return nil }

        bodyLines[lineIndex] = newLine
        let newBody = bodyLines.joined(separator: "\n")
        if let frontmatter {
            return frontmatter + "\n" + newBody
        }
        return newBody
    }

    /// Matches a task-list item marker at the start of a line (after
    /// optional leading indentation): a `-`/`*`/`+` bullet, one space,
    /// then `[ ]` or `[x]`/`[X]`. Group 1 is everything up to and
    /// including the opening `[`, group 2 is the state character, group 3
    /// is the closing `]` and everything after — reconstructing the line
    /// from those three groups with only the state character replaced
    /// preserves the rest of the line byte-for-byte.
    private static let markerPattern = try! NSRegularExpression(
        pattern: #"^(\s*[-*+]\s\[)([ xX])(\].*)$"#)

    private static func flippedLine(_ line: String, checked: Bool) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = markerPattern.firstMatch(in: line, range: range),
              let prefixRange = Range(match.range(at: 1), in: line),
              let stateRange = Range(match.range(at: 2), in: line),
              let suffixRange = Range(match.range(at: 3), in: line)
        else { return nil }

        let currentlyChecked = line[stateRange].lowercased() == "x"
        guard currentlyChecked != checked else { return nil }

        let newState = checked ? "x" : " "
        return String(line[prefixRange]) + newState + String(line[suffixRange])
    }
}
