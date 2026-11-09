import AppKit
import CoreServices
import TypesetRendering
import Observation

/// Folder mode (PLAN §3 v1.x): the Markdown files under a folder the user
/// opened, as a flat most-recent-first list for the sidebar's Files section
/// and Open Quickly. A reading list, not a library — no tags, no metadata.
/// Kept current by an FSEventStream on the root.
@Observable
@MainActor
final class FolderIndex {
    struct Entry: Identifiable, Hashable, Sendable {
        let url: URL
        /// Path from the root, e.g. `.claude/plans/next.md`.
        let relativePath: String
        let modified: Date
        var id: URL { url }
        var name: String { url.lastPathComponent }
        /// The containing folder relative to the root; empty at the top level.
        var folder: String { (relativePath as NSString).deletingLastPathComponent }
    }

    let root: URL
    private(set) var files: [Entry] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var rescanTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var stream: FSEventStreamRef?

    init(root: URL) {
        self.root = root.standardizedFileURL
        rescan()
        watch()
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func contains(_ url: URL) -> Bool {
        FolderAccessPathing.isPath(url.standardizedFileURL.path, containedIn: root.path)
    }

    private func rescan() {
        generation += 1
        let generation = generation
        let root = root
        Task.detached(priority: .utility) { [weak self] in
            let files = Self.scan(root)
            await MainActor.run { [weak self] in
                guard let self, self.generation == generation else { return }
                self.files = files
            }
        }
    }

    /// FSEvents already coalesces within `latency`, which is the debounce.
    private func watch() {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let index = Unmanaged<FolderIndex>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            MainActor.assumeIsolated { index.filesystemChanged(paths) }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func filesystemChanged(_ paths: [String]) {
        // Skip churn inside excluded trees (git, node_modules builds…).
        let relevant = paths.contains { path in
            !path.split(separator: "/").contains { Self.excluded.contains(String($0)) }
        }
        guard relevant else { return }
        // A busy tree (an agent writing, a build) fires event after event;
        // rescan once things settle instead of per batch.
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.rescan()
        }
    }

    // MARK: - Scanning (pure)

    nonisolated static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mdx"]
    nonisolated static let excluded: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", "Pods", "vendor", "dist",
        ".venv", "venv", "target", "__pycache__", ".next", "build",
    ]

    /// Every Markdown file under `root`, dot-folders included (`.claude`,
    /// `.github`), heavy build/vendor trees excluded, newest first.
    // ponytail: hard cap of `limit` files / `maxDepth` levels / `maxVisited`
    // filesystem entries in enumeration order, so a huge tree (a home
    // folder) silently truncates; paginate or warn if real repos hit it.
    nonisolated static func scan(_ root: URL, limit: Int = 2_000, maxDepth: Int = 8, maxVisited: Int = 50_000) -> [Entry] {
        let root = root.standardizedFileURL
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var result: [Entry] = []
        var visited = 0
        while visited < maxVisited, let url = enumerator.nextObject() as? URL, result.count < limit {
            visited += 1
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if excluded.contains(url.lastPathComponent) || enumerator.level >= maxDepth {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard markdownExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let path = url.standardizedFileURL.path
            result.append(Entry(
                url: url.standardizedFileURL,
                relativePath: path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent,
                modified: values?.contentModificationDate ?? .distantPast))
        }
        return result.sorted { $0.modified > $1.modified }
    }

    /// The file a freshly opened folder shows: README, else the agent
    /// instruction files, else whatever changed last.
    nonisolated static func entryFile(in files: [Entry]) -> Entry? {
        for name in ["readme.md", "claude.md", "agents.md"] {
            if let hit = files.first(where: { $0.relativePath.lowercased() == name }) { return hit }
        }
        return files.first
    }

    // MARK: - Ranking (pure)

    /// Open Quickly ranking: filename prefix, then filename substring, then
    /// filename subsequence, then path subsequence; ties keep input order
    /// (most recent first). Empty query returns everything as-is.
    nonisolated static func rank(_ query: String, in files: [Entry]) -> [Entry] {
        let q = query.lowercased().filter { !$0.isWhitespace }
        guard !q.isEmpty else { return files }
        return files.enumerated().compactMap { offset, entry -> (Int, Int, Entry)? in
            let name = entry.name.lowercased()
            let tier: Int
            if name.hasPrefix(q) { tier = 0 }
            else if name.contains(q) { tier = 1 }
            else if isSubsequence(q, of: name) { tier = 2 }
            else if isSubsequence(q, of: entry.relativePath.lowercased()) { tier = 3 }
            else { return nil }
            return (tier, offset, entry)
        }
        .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        .map(\.2)
    }

    /// Character offsets in `name` to bold in Open Quickly (R07): the first
    /// substring hit, else greedy subsequence positions; empty when the match
    /// was only in the path.
    nonisolated static func matchedOffsets(_ query: String, in name: String) -> [Int] {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        let n = Array(name.lowercased())
        guard !q.isEmpty, q.count <= n.count else { return [] }
        if let start = (0...(n.count - q.count)).first(where: { Array(n[$0..<$0 + q.count]) == q }) {
            return Array(start..<start + q.count)
        }
        var hits: [Int] = []
        for (i, c) in n.enumerated() where hits.count < q.count && c == q[hits.count] { hits.append(i) }
        return hits.count == q.count ? hits : []
    }

    nonisolated private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var rest = needle[...]
        for char in haystack where char == rest.first {
            rest = rest.dropFirst()
            if rest.isEmpty { return true }
        }
        return rest.isEmpty
    }

    // MARK: - Opened folders

    private static let rootsKey = "folderModeRoots"

    /// Folders the user opened with Open Folder…, most recent first. A file
    /// later opened from Finder inside one gets the Files section too.
    static func rememberedRoot(covering url: URL) -> URL? {
        let roots = UserDefaults.standard.stringArray(forKey: rootsKey) ?? []
        guard let path = FolderAccessPathing.coveringFolder(for: url.standardizedFileURL.path, among: roots) else { return nil }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        return FolderAccessStore.shared.access(to: root) ? root : nil
    }

    static func remember(_ root: URL) {
        let path = root.standardizedFileURL.path
        var roots = UserDefaults.standard.stringArray(forKey: rootsKey) ?? []
        roots.removeAll { $0 == path }
        roots.insert(path, at: 0)
        UserDefaults.standard.set(Array(roots.prefix(20)), forKey: rootsKey)
    }
}

// MARK: - Opening a folder

extension DocumentOpener {
    /// File ▸ Open Folder… (⇧⌘O).
    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFolder(url)
    }

    /// Grants (and persists) access to `root`, then opens its entry file; the
    /// window picks the folder up via `FolderIndex.rememberedRoot`.
    func openFolder(_ root: URL) {
        guard FolderAccessStore.shared.grant(folder: root) else {
            NSSound.beep()
            return
        }
        Task.detached(priority: .userInitiated) {
            let files = FolderIndex.scan(root)
            await MainActor.run {
                guard let entry = FolderIndex.entryFile(in: files) else { NSSound.beep(); return }
                FolderIndex.remember(root)
                self.open(entry.url)
            }
        }
    }
}

extension URL {
    var isDirectory: Bool { (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
}

// MARK: - Window hooks

extension WindowModel {
    /// Attaches the opened folder covering `url`, if any (once per window).
    func attachFolderIfNeeded(for url: URL) {
        guard folder == nil, let root = FolderIndex.rememberedRoot(covering: url) else { return }
        folder = FolderIndex(root: root)
        showsOutline = true
    }

    /// The folder Open Quickly searches: the opened folder, else the current
    /// file's folder when the sandbox lets us read it.
    var quickOpenRoot: URL? {
        if let folder { return folder.root }
        guard let parent = currentURL?.deletingLastPathComponent(),
              FolderAccessStore.shared.access(to: parent) else { return nil }
        return parent
    }
}
