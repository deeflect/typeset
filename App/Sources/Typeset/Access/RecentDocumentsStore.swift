import AppKit
import Foundation
import os

/// The empty-state "home screen" recent-files list (PLAN §6). Persists a
/// small, ordered set of security-scoped bookmarks for documents the user
/// has actually opened, so the no-document window can re-open them under the
/// sandbox with a single click — mirroring `FolderAccessStore`'s bookmark
/// handling, but keyed per file and capped/ordered by recency.
@MainActor
@Observable
final class RecentDocumentsStore {
    static let shared = RecentDocumentsStore()

    /// A resolved, openable recent. `url` already has its security scope
    /// started (held for the process lifetime) so reading it just works.
    struct Entry: Identifiable, Equatable {
        let url: URL
        var id: String { url.path }
        var name: String { url.lastPathComponent }
        /// The containing folder, abbreviated with `~`, for a quiet subtitle.
        var location: String {
            (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        }
    }

    private(set) var entries: [Entry] = []

    private let maxCount = 8
    private static let defaultsKey = "com.deeflect.typeset.recentDocuments"
    private static let log = Logger(subsystem: "com.deeflect.typeset", category: "RecentDocumentsStore")

    private init() {
        loadPersisted()
    }

    /// Records `url` as the most-recent document. Creates a fresh
    /// security-scoped bookmark (the file is readable right now — it was just
    /// opened), moves it to the front, dedupes, and caps the list.
    func record(_ url: URL) {
        let std = url.standardizedFileURL
        guard std.isFileURL else { return }

        var stored = persistedDict()
        // Bookmarking needs live access; the opened doc already has it, but a
        // sibling reached via a folder grant may need its scope started first.
        let didStart = std.startAccessingSecurityScopedResource()
        defer { if didStart { std.stopAccessingSecurityScopedResource() } }
        guard let data = try? std.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
        ) else { return }
        stored[std.path] = BookmarkRecord(bookmark: data, openedAt: Date())

        // Keep only the newest `maxCount` by openedAt.
        let trimmed = Array(stored.sorted { $0.value.openedAt > $1.value.openedAt }.prefix(maxCount))
        var kept: [String: BookmarkRecord] = [:]
        for (path, record) in trimmed { kept[path] = record }
        writePersisted(kept)
        rebuildEntries(from: kept)
    }

    /// Removes one entry (e.g. a "Clear" affordance, or a file that no longer
    /// resolves). Stops its scope and drops the bookmark.
    func remove(_ entry: Entry) {
        entry.url.stopAccessingSecurityScopedResource()
        var stored = persistedDict()
        stored.removeValue(forKey: entry.url.standardizedFileURL.path)
        writePersisted(stored)
        rebuildEntries(from: stored)
    }

    #if DEBUG
    /// Snapshot/preview seam: populate the list with plain file URLs (no
    /// bookmarks) so the empty-state home screen can be captured headlessly.
    func seedForSnapshot(_ urls: [URL]) {
        entries = urls.map { Entry(url: $0.standardizedFileURL) }
    }
    #endif

    func clear() {
        for entry in entries { entry.url.stopAccessingSecurityScopedResource() }
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        entries = []
    }

    // MARK: - Persistence

    private struct BookmarkRecord: Codable, Equatable {
        var bookmark: Data
        var openedAt: Date
    }

    private func persistedDict() -> [String: BookmarkRecord] {
        guard let raw = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: BookmarkRecord].self, from: raw)
        else { return [:] }
        return decoded
    }

    private func writePersisted(_ dict: [String: BookmarkRecord]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private func loadPersisted() {
        rebuildEntries(from: persistedDict())
    }

    /// Resolves every stored bookmark, starts its scope, and publishes the
    /// live `entries` ordered newest-first. Drops bookmarks that no longer
    /// resolve (file moved/deleted) so the list self-heals.
    private func rebuildEntries(from dict: [String: BookmarkRecord]) {
        // Stop any scopes we currently hold before re-resolving.
        for entry in entries { entry.url.stopAccessingSecurityScopedResource() }

        var resolved: [(entry: Entry, openedAt: Date)] = []
        var pruned = dict
        for (path, record) in dict {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: record.bookmark, options: [.withSecurityScope],
                relativeTo: nil, bookmarkDataIsStale: &isStale
            ), url.startAccessingSecurityScopedResource() else {
                pruned.removeValue(forKey: path)
                continue
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                url.stopAccessingSecurityScopedResource()
                pruned.removeValue(forKey: path)
                continue
            }
            if isStale, let refreshed = try? url.bookmarkData(
                options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
            ) {
                pruned[path]?.bookmark = refreshed
            }
            resolved.append((Entry(url: url), record.openedAt))
        }

        if pruned != dict { writePersisted(pruned) }
        entries = resolved.sorted { $0.openedAt > $1.openedAt }.map(\.entry)
        Self.log.debug("\(self.entries.count, privacy: .public) recent document(s)")
    }
}
