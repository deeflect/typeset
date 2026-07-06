import AppKit
import Foundation
import os

/// Pure ancestor-walk over folder paths — no bookmark/security-scope APIs,
/// so it's plainly unit-testable. "Contained in" means equal to, or nested
/// under, a folder path; used both to answer `access(to:)` and to decide
/// whether a folder (or any of its subfolders) has already been granted, so
/// we never prompt twice for the same tree (PLAN §8 risk #5).
enum FolderAccessPathing {
    static func isPath(_ candidate: String, containedIn folder: String) -> Bool {
        let normFolder = normalize(folder)
        let normCandidate = normalize(candidate)
        guard !normFolder.isEmpty else { return false }
        if normCandidate == normFolder { return true }
        return normCandidate.hasPrefix(normFolder + "/")
    }

    /// The first granted folder (if any) that already covers `candidate`.
    static func coveringFolder(for candidate: String, among granted: [String]) -> String? {
        granted.first { isPath(candidate, containedIn: $0) }
    }

    private static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

/// Persists security-scoped bookmarks for folders the user has explicitly
/// granted access to (via the "Allow access to <folder>" affordance on a
/// broken relative link/image), so sibling files under an already-granted
/// folder — and any of its subfolders — never re-prompt. Resolves and
/// starts accessing every persisted bookmark once, at first use, and keeps
/// each folder's security scope open for the process lifetime (mirrors how
/// `DocumentReloadController` holds the opened document's own scope).
@MainActor
final class FolderAccessStore {
    static let shared = FolderAccessStore()

    /// Posted after a new folder grant is stored (and its scope started),
    /// so already-visible views (image cards) can re-attempt their load in
    /// place without needing a central registry of pending loads.
    static let accessGrantedNotification = Notification.Name("FolderAccessStore.accessGranted")

    private struct ActiveGrant {
        let path: String
        let url: URL
    }

    private var active: [ActiveGrant] = []
    /// Paths of documents currently open in a window — the "exact-file
    /// grant" step of the walk in `access(to:)`. These already carry their
    /// own implicit security scope (from the Finder/Open-panel launch) for
    /// as long as the window is open; sibling files are a separate,
    /// folder-level concern handled by `active` below.
    private var openDocumentPaths: Set<String> = []

    private static let defaultsKey = "com.dee.marco.draft.folderAccessBookmarks"
    private static let log = Logger(subsystem: "com.dee.marco.draft", category: "FolderAccessStore")

    private init() {
        loadPersistedBookmarks()
    }

    // MARK: - Document lifecycle (exact-file grant)

    func noteDocumentOpened(_ url: URL) {
        openDocumentPaths.insert(url.standardizedFileURL.path)
    }

    func noteDocumentClosed(_ url: URL) {
        openDocumentPaths.remove(url.standardizedFileURL.path)
    }

    // MARK: - Query

    /// Walks: exact-file grant (the opened doc) first, then any stored
    /// ancestor-folder bookmark.
    func access(to url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if openDocumentPaths.contains(path) { return true }
        return FolderAccessPathing.coveringFolder(for: path, among: active.map(\.path)) != nil
    }

    /// True if `url` isn't readable *because* the sandbox denied it (rather
    /// than, say, the file simply not existing) — distinguishes "show the
    /// Allow-access affordance" from "show a generic unavailable state".
    /// Sandbox denials surface as `EPERM`; a missing file is `ENOENT`.
    nonisolated static func isAccessDenied(at url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let fd = open(url.path, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return false
        }
        return errno == EPERM || errno == EACCES
    }

    // MARK: - Granting

    /// Presents an `NSOpenPanel` for the user to pick (or confirm) the
    /// folder to grant, stores a persisted security-scoped bookmark, and
    /// starts accessing it immediately. Only ever called from the user's
    /// explicit tap on the access-hint affordance — never spontaneously.
    @discardableResult
    func requestAccess(defaultDirectory: URL, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = defaultDirectory
        panel.message = message
        panel.prompt = "Allow"
        guard panel.runModal() == .OK, let folderURL = panel.url else { return nil }
        return grant(folder: folderURL) ? folderURL : nil
    }

    /// Stores + starts accessing a security-scoped bookmark for `folderURL`.
    /// Split out from `requestAccess` so a verification harness can grant a
    /// folder directly, without an interactive panel. Skips the store if
    /// the folder (or an ancestor of it) is already granted.
    @discardableResult
    func grant(folder folderURL: URL) -> Bool {
        let std = folderURL.standardizedFileURL
        guard FolderAccessPathing.coveringFolder(for: std.path, among: active.map(\.path)) == nil else {
            return true
        }
        guard let data = try? std.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
        ) else { return false }

        var dict = (UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: Data]) ?? [:]
        dict[std.path] = data
        UserDefaults.standard.set(dict, forKey: Self.defaultsKey)

        guard std.startAccessingSecurityScopedResource() else { return false }
        active.append(ActiveGrant(path: std.path, url: std))
        NotificationCenter.default.post(name: Self.accessGrantedNotification, object: nil)
        return true
    }

    // MARK: - Startup

    private func loadPersistedBookmarks() {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: Data] else {
            Self.log.debug("no persisted folder grants")
            return
        }
        var updated = dict
        var staleKeys: [String] = []

        for (path, data) in dict {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data, options: [.withSecurityScope],
                relativeTo: nil, bookmarkDataIsStale: &isStale
            ) else {
                staleKeys.append(path)
                continue
            }
            guard url.startAccessingSecurityScopedResource() else {
                staleKeys.append(path)
                continue
            }
            if isStale, let refreshed = try? url.bookmarkData(
                options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
            ) {
                updated[path] = refreshed
            }
            active.append(ActiveGrant(path: url.standardizedFileURL.path, url: url))
        }

        for key in staleKeys { updated.removeValue(forKey: key) }
        if updated != dict { UserDefaults.standard.set(updated, forKey: Self.defaultsKey) }

        Self.log.debug("\(self.active.count, privacy: .public) active grant(s) at startup: \(self.active.map(\.path).joined(separator: ", "), privacy: .public)")
    }

    // MARK: - Hygiene (Settings pane TBD — see PLAN §8)

    /// Stops accessing and forgets every granted folder. Unused today; kept
    /// so a future Settings "Manage folder access" pane is a small addition
    /// rather than new plumbing.
    func revokeAll() {
        for grant in active { grant.url.stopAccessingSecurityScopedResource() }
        active.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }
}
