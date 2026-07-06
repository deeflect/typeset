import Foundation

/// Bounded, thread-safe cache of `BlockStructure`'s parsed models, keyed by
/// a block's content hash.
///
/// `BlockStructure` re-parses a block's `rawText` from scratch (cheap for a
/// single block, but not free); with a `LazyVStack` driving rendering, this
/// cache means only blocks that have actually scrolled into view ever get
/// parsed, and scrolling back to an already-seen block is free.
///
/// Keyed by `Block.contentHash` — not `Block.id`, which also carries an
/// ordinal that can shift across reparses/incremental edits — so cached
/// structure stays valid for any block whose text hasn't changed.
public final class BlockStructureCache: @unchecked Sendable {
    public static let shared = BlockStructureCache()

    private let lock = NSLock()
    private var lists: [String: ListModel?] = [:]
    private var tables: [String: TableModel?] = [:]
    private var quotes: [String: QuoteModel?] = [:]
    private var headings: [String: String] = [:]
    private let limit = 2000

    private init() {}

    public func list(for block: Block) -> ListModel? {
        cached(&lists, key: block.contentHash) { BlockStructure.list(block.rawText) }
    }

    public func table(for block: Block) -> TableModel? {
        cached(&tables, key: block.contentHash) { BlockStructure.table(block.rawText) }
    }

    public func quote(for block: Block) -> QuoteModel? {
        cached(&quotes, key: block.contentHash) { BlockStructure.quote(block.rawText) }
    }

    public func headingText(for block: Block) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let hit = headings[block.contentHash] { return hit }
        let value = BlockStructure.headingText(block.rawText)
        if headings.count > limit { headings.removeAll(keepingCapacity: true) }
        headings[block.contentHash] = value
        return value
    }

    /// `store`'s `Value` type is itself an `Optional` model (e.g.
    /// `ListModel?`), so a hit is `store[key]: Value?` unwrapping once to
    /// `Value` — which may still legitimately be `nil` (a cached "this
    /// block has no such structure" result).
    private func cached<Value>(_ store: inout [String: Value], key: String, compute: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        if let hit = store[key] { return hit }
        let value = compute()
        if store.count > limit { store.removeAll(keepingCapacity: true) }
        store[key] = value
        return value
    }
}
