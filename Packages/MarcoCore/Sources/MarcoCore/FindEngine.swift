import Foundation

/// A single match produced by `FindEngine.search`. Offsets are Character
/// (grapheme cluster) counts into the matched segment, so callers can
/// convert to `String.Index`/`AttributedString.Index` without worrying
/// about UTF-8/UTF-16 byte width.
public struct FindMatch: Identifiable, Equatable, Sendable {
    /// Global 0-based order across all segments (segment order, then
    /// position order within a segment).
    public let id: Int
    /// Index into the `segments` array passed to `search`.
    public let segmentIndex: Int
    /// Character offset into `segments[segmentIndex]` where the match
    /// starts.
    public let start: Int
    /// Match length, in Characters.
    public let length: Int
}

/// A pure, view-agnostic text search over an array of text segments (e.g.
/// one per rendered block), used to power find-in-document (Cmd-F).
/// Foundation-only — no SwiftUI/AppKit dependency.
public enum FindEngine {
    /// Finds every non-overlapping occurrence of `query` across `segments`,
    /// in segment order then position order. Case-insensitive unless
    /// `caseSensitive` is true. An empty or whitespace-only `query` returns
    /// no matches.
    public static func search(query: String, in segments: [String], caseSensitive: Bool = false) -> [FindMatch] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        var matches: [FindMatch] = []
        var nextID = 0
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]

        for (segmentIndex, segment) in segments.enumerated() {
            var searchStart = segment.startIndex
            while searchStart < segment.endIndex {
                guard let found = segment.range(
                    of: query, options: options, range: searchStart..<segment.endIndex
                ) else { break }

                let start = segment.distance(from: segment.startIndex, to: found.lowerBound)
                let length = segment.distance(from: found.lowerBound, to: found.upperBound)
                matches.append(FindMatch(id: nextID, segmentIndex: segmentIndex, start: start, length: length))
                nextID += 1

                if found.upperBound > searchStart {
                    searchStart = found.upperBound
                } else {
                    // Zero-length match (shouldn't normally happen for a
                    // non-empty query, but guard against an infinite loop).
                    searchStart = segment.index(after: found.upperBound)
                }
            }
        }

        return matches
    }
}
