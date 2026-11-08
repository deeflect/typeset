import CryptoKit
import Foundation

/// The block ids each document had when it was last left, so the next open
/// can mark what changed in between. One small JSON file per path hash in
/// Application Support; the least recently written files past `limit` are
/// dropped.
@MainActor
final class LastViewedStore {
    static let shared = LastViewedStore()

    private let directory: URL
    private let limit: Int
    /// ponytail: documents above this many blocks aren't remembered (keeps
    /// each file small); store a digest per block range if huge docs matter.
    static let maxBlocks = 5_000

    init(directory: URL? = nil, limit: Int = 200) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LastViewed", isDirectory: true)
        self.limit = limit
    }

    func blockIDs(for url: URL) -> Set<String>? {
        guard let data = try? Data(contentsOf: file(for: url)),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return Set(ids)
    }

    func record(_ ids: [String], for url: URL) {
        guard ids.count <= Self.maxBlocks, let data = try? JSONEncoder().encode(ids) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(for: url), options: .atomic)
        prune()
    }

    private func prune() {
        let key = URLResourceKey.contentModificationDateKey
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [key]),
              files.count > limit else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [key]).contentModificationDate) ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(limit) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func file(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        return directory.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined() + ".json")
    }
}
