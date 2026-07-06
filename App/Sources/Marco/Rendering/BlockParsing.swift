import Foundation

/// Lightweight, line-oriented parsers that turn a single block's `rawText`
/// into the structure the corresponding view needs. GFM lists, tables, and
/// blockquotes are line-based by construction, so this stays simple and
/// fast (no AST re-parse) and keeps all render-side logic in the app target
/// without touching the core parser.
enum BlockParsing {

    // MARK: - Headings

    /// Strips ATX `#` markers (and a closing `###`) or a setext underline,
    /// returning just the inline heading text.
    static func headingText(_ raw: String) -> String {
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Drop a trailing setext underline (==== or ----).
        if lines.count > 1 {
            let last = lines[lines.count - 1].trimmingCharacters(in: .whitespaces)
            if !last.isEmpty, last.allSatisfy({ $0 == "=" }) || last.allSatisfy({ $0 == "-" }) {
                lines.removeLast()
            }
        }
        var text = lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        while text.hasPrefix("#") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespaces)
        // Closing ATX sequence: "## Title ##"
        while text.hasSuffix("#") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Lists

    enum ListMarker: Equatable {
        case bullet
        case ordered(Int)
        case task(Bool)
    }

    struct ListRow: Identifiable {
        let id: Int
        var depth: Int
        var marker: ListMarker
        var text: String
    }

    static func listRows(_ raw: String) -> [ListRow] {
        var rows: [ListRow] = []
        var indentStack: [Int] = []
        var nextID = 0

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            let indent = leadingSpaces(line)
            guard let (marker, content) = parseMarker(line.drop { $0 == " " || $0 == "\t" }) else {
                // Continuation / wrapped line — fold into the previous row.
                if !rows.isEmpty {
                    rows[rows.count - 1].text += " " + line.trimmingCharacters(in: .whitespaces)
                }
                continue
            }

            while let last = indentStack.last, indent < last { indentStack.removeLast() }
            if let last = indentStack.last {
                if indent > last { indentStack.append(indent) }
            } else {
                indentStack.append(indent)
            }
            let depth = max(0, indentStack.count - 1)

            rows.append(ListRow(id: nextID, depth: depth, marker: marker, text: content))
            nextID += 1
        }
        return rows
    }

    private static func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for ch in line {
            if ch == " " { count += 1 }
            else if ch == "\t" { count += 4 }
            else { break }
        }
        return count
    }

    /// Parses a leading list marker from an already-indent-trimmed line.
    private static func parseMarker(_ trimmed: Substring) -> (ListMarker, String)? {
        // Task item: - [ ] / - [x]
        if trimmed.count >= 2, "-*+".contains(trimmed.first!) {
            let afterBullet = trimmed.dropFirst()
            guard afterBullet.first == " " || afterBullet.first == "\t" else { return nil }
            let content = afterBullet.drop { $0 == " " || $0 == "\t" }
            if content.hasPrefix("[ ]") || content.hasPrefix("[x]") || content.hasPrefix("[X]") {
                let checked = content.hasPrefix("[x]") || content.hasPrefix("[X]")
                let rest = content.dropFirst(3).drop { $0 == " " || $0 == "\t" }
                return (.task(checked), String(rest))
            }
            return (.bullet, String(content))
        }
        // Ordered: 1. or 1)
        var digits = ""
        var rest = trimmed
        while let f = rest.first, f.isNumber { digits.append(f); rest = rest.dropFirst() }
        if !digits.isEmpty, let f = rest.first, f == "." || f == ")" {
            let after = rest.dropFirst()
            guard after.first == " " || after.first == "\t" else { return nil }
            let content = after.drop { $0 == " " || $0 == "\t" }
            return (.ordered(Int(digits) ?? 1), String(content))
        }
        return nil
    }

    // MARK: - Tables

    enum ColumnAlignment { case leading, center, trailing }

    struct TableModel {
        var alignments: [ColumnAlignment]
        var header: [String]
        var rows: [[String]]
    }

    static func table(_ raw: String) -> TableModel? {
        let lines = raw.split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return nil }

        let header = splitCells(lines[0])
        let columns = header.count

        var alignments = splitCells(lines[1]).map { spec -> ColumnAlignment in
            let s = spec.trimmingCharacters(in: .whitespaces)
            let left = s.hasPrefix(":")
            let right = s.hasSuffix(":")
            if left && right { return .center }
            if right { return .trailing }
            return .leading
        }
        if alignments.count < columns {
            alignments += Array(repeating: .leading, count: columns - alignments.count)
        }

        func pad(_ cells: [String]) -> [String] {
            var c = cells
            if c.count < columns { c += Array(repeating: "", count: columns - c.count) }
            else if c.count > columns { c = Array(c.prefix(columns)) }
            return c
        }
        return TableModel(
            alignments: Array(alignments.prefix(columns)),
            header: header,
            rows: lines.dropFirst(2).map { pad(splitCells($0)) })
    }

    private static func splitCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        // Split on unescaped pipes.
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in trimmed {
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                current.append(ch)
                escaped = true
            } else if ch == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: - Blockquotes

    struct QuoteParagraph: Identifiable {
        let id: Int
        var depth: Int
        var text: String
    }

    /// Splits quote source into paragraphs, each carrying its `>` nesting
    /// depth so the view can deepen the accent bar for nested quotes.
    static func quoteParagraphs(_ raw: String) -> [QuoteParagraph] {
        var paragraphs: [QuoteParagraph] = []
        var currentDepth = -1
        var currentText = ""
        var nextID = 0

        func flush() {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                paragraphs.append(QuoteParagraph(id: nextID, depth: max(0, currentDepth), text: trimmed))
                nextID += 1
            }
            currentText = ""
        }

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = Substring(rawLine)
            var depth = 0
            // Count and strip leading `>` markers (allowing a space after each).
            while true {
                let stripped = line.drop { $0 == " " }
                if stripped.first == ">" {
                    depth += 1
                    line = stripped.dropFirst()
                    if line.first == " " { line = line.dropFirst() }
                } else {
                    line = stripped
                    break
                }
            }
            let content = String(line)
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                currentDepth = -1
                continue
            }
            if depth != currentDepth && !currentText.isEmpty {
                flush()
            }
            currentDepth = depth
            currentText += currentText.isEmpty ? content : " " + content
        }
        flush()
        return paragraphs
    }
}
