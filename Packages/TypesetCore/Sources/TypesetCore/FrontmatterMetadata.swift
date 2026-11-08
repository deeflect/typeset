import Foundation

/// One top-level frontmatter key, in document order.
public struct FrontmatterEntry: Equatable, Sendable {
    public let key: String
    public let value: FrontmatterValue
}

public enum FrontmatterValue: Equatable, Sendable {
    /// Plain or quoted scalar (quotes removed), or a `|`/`>` block scalar. Empty for `key:` with nothing after.
    case string(String)
    /// `text` is the source spelling (`1.10` stays `1.10`).
    case number(Double, text: String)
    case bool(Bool)
    /// ISO-like `2026-11-05` / `2026-11-05T10:00:00Z`; `text` is the source spelling.
    case date(Date, text: String)
    /// Inline `[a, b]` or block `- a` list of scalars (quotes removed).
    case list([String])
    /// Anything nested or complex: the key's YAML value text, dedented.
    case raw(String)
}

/// Small line-based reader for the flat YAML people put in frontmatter.
/// ponytail: not a YAML parser — anchors, multi-line plain scalars, quoted keys etc. come back
/// as `.raw` or nil; add a real YAML dependency only if headers need more than one level.
public enum FrontmatterMetadata {

    /// Entries for a frontmatter block (with or without its `---` fences), or nil if it isn't
    /// the simple `key: value` shape — callers then show the raw text.
    public static func entries(_ text: String) -> [FrontmatterEntry]? {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" { lines.removeFirst() }
        if let last = lines.last?.trimmingCharacters(in: .whitespaces), last == "---" || last == "..." { lines.removeLast() }

        var entries: [FrontmatterEntry] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // A top-level line must be an unindented `key:`.
            guard line.first?.isWhitespace == false,
                  let match = line.firstMatch(of: /^([A-Za-z0-9_$][A-Za-z0-9_ .$-]*?)[ \t]*:(?:[ \t]+(.*))?$/) else { return nil }
            let key = String(match.1)
            let rest = match.2.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""

            var block: [String] = []
            while index < lines.count {
                let next = lines[index]
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                // Unindented `- item` lines also belong to the key (YAML allows that for sequences).
                guard nextTrimmed.isEmpty || next.first?.isWhitespace == true || (rest.isEmpty && nextTrimmed.hasPrefix("-")) else { break }
                block.append(next)
                index += 1
            }
            while let last = block.last, last.trimmingCharacters(in: .whitespaces).isEmpty { block.removeLast() }

            guard let value = value(rest: rest, block: block) else { return nil }
            entries.append(FrontmatterEntry(key: key, value: value))
        }
        return entries.isEmpty ? nil : entries
    }

    private static func value(rest: String, block: [String]) -> FrontmatterValue? {
        let body = dedented(block)
        if rest == "|" || rest == ">" || rest.hasPrefix("|") || rest.hasPrefix(">") {
            return .string(rest.hasPrefix("|") ? body.joined(separator: "\n") : body.joined(separator: " "))
        }
        if !rest.isEmpty {
            guard block.isEmpty else { return .raw(([rest] + body).joined(separator: "\n")) }
            return scalarOrInline(rest)
        }
        if body.isEmpty { return .string("") }
        // Block list of plain scalars; anything nested under an item is raw.
        if body.allSatisfy({ $0.hasPrefix("- ") || $0 == "-" }) {
            var items: [String] = []
            for line in body {
                let item = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                guard let value = scalar(item), !item.hasPrefix("["), !item.hasPrefix("{"),
                      item.firstMatch(of: /^[^"'].*?:(\s|$)/) == nil else { return .raw(body.joined(separator: "\n")) }
                if case .string(let text) = value { items.append(text) } else { items.append(item) }
            }
            return .list(items)
        }
        return .raw(body.joined(separator: "\n"))
    }

    private static func scalarOrInline(_ text: String) -> FrontmatterValue? {
        if text.hasPrefix("[") {
            guard text.hasSuffix("]") else { return nil }
            let inner = text.dropFirst().dropLast()
            if inner.contains("[") || inner.contains("{") { return .raw(text) }
            guard let parts = splitCommas(String(inner)) else { return nil }
            var items: [String] = []
            for part in parts where !part.isEmpty {
                guard let value = scalar(part) else { return nil }
                if case .string(let s) = value { items.append(s) } else { items.append(part) }
            }
            return .list(items)
        }
        if text.hasPrefix("{") { return text.hasSuffix("}") ? .raw(text) : nil }
        return scalar(text)
    }

    /// A single scalar; nil for an unterminated quote.
    private static func scalar(_ raw: String) -> FrontmatterValue? {
        if raw.hasPrefix("\"") {
            guard let end = closingQuote(raw, "\"") else { return nil }
            let inner = String(raw[raw.index(after: raw.startIndex)..<end])
            return .string(inner.replacingOccurrences(of: "\\\\", with: "\u{0}")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
                .replacingOccurrences(of: "\u{0}", with: "\\"))
        }
        if raw.hasPrefix("'") {
            guard let end = closingQuote(raw, "'") else { return nil }
            return .string(String(raw[raw.index(after: raw.startIndex)..<end]).replacingOccurrences(of: "''", with: "'"))
        }
        // Strip a trailing ` # comment` from plain scalars.
        let text = (raw.range(of: " #").map { String(raw[..<$0.lowerBound]) } ?? raw).trimmingCharacters(in: .whitespaces)
        switch text {
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        default: break
        }
        if text.wholeMatch(of: /[-+]?(\d+(\.\d*)?|\.\d+)([eE][-+]?\d+)?/) != nil, let number = Double(text) {
            return .number(number, text: text)
        }
        if text.wholeMatch(of: /\d{4}-\d{2}-\d{2}([Tt ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?\s*(Z|[+-]\d{2}(:?\d{2})?)?)?/) != nil,
           let date = parseDate(text) {
            return .date(date, text: text)
        }
        return .string(text)
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if text.count == 10 {
            formatter.formatOptions = [.withFullDate]
            return formatter.date(from: text)
        }
        let normalized = text.replacingOccurrences(of: " ", with: "T", options: [], range: text.range(of: " "))
            .replacingOccurrences(of: " ", with: "")
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds],
            [.withFullDate, .withTime, .withColonSeparatorInTime],
        ] {
            formatter.formatOptions = options
            if let date = formatter.date(from: normalized) { return date }
        }
        // `2026-11-05T10:00` (no seconds/zone): read as UTC.
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.timeZone = TimeZone(identifier: "UTC")
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return fallback.date(from: normalized)
    }

    /// Index of the quote closing `text`'s opening quote, if it ends the scalar (comments allowed after).
    private static func closingQuote(_ text: String, _ quote: Character) -> String.Index? {
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let char = text[index]
            if quote == "\"" && char == "\\" {
                index = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                continue
            }
            if char == quote {
                let after = text.index(after: index)
                if quote == "'", after < text.endIndex, text[after] == "'" { index = text.index(after: after); continue }
                let tail = text[after...].trimmingCharacters(in: .whitespaces)
                return tail.isEmpty || tail.hasPrefix("#") ? index : nil
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Splits on commas outside quotes; nil on an unterminated quote.
    private static func splitCommas(_ text: String) -> [String]? {
        var parts: [String] = [], current = "", quote: Character?
        for char in text {
            if let q = quote {
                if char == q { quote = nil }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == "," {
                parts.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue
            }
            current.append(char)
        }
        guard quote == nil else { return nil }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts
    }

    private static func dedented(_ lines: [String]) -> [String] {
        let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }.min() ?? 0
        return lines.map { String($0.dropFirst(min(indent, $0.prefix(while: { $0 == " " || $0 == "\t" }).count))) }
    }
}
