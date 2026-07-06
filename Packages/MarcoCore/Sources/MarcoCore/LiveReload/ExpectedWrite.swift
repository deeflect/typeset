import Foundation

/// Suppresses the file watcher's echo of the app's own saves.
///
/// M2 only *consumes* file-system changes (the watcher/reload pipeline);
/// M3 adds the save path. This type is the hook M3's save path will call
/// into (`beginExpecting`) so a save the app itself performs doesn't bounce
/// straight back as a reload. Pure value type — no `Date()`/timer
/// dependency baked in, so it's trivially unit-testable by passing
/// explicit `Date`s.
public struct ExpectedWriteWindow: Equatable, Sendable {
    private var expiresAt: Date?

    public init() {}

    /// Call right before the app writes the file itself. Any watcher event
    /// observed before `duration` seconds have elapsed is treated as an
    /// echo of this write, not an external change.
    public mutating func beginExpecting(now: Date, duration: TimeInterval = 2.0) {
        expiresAt = now.addingTimeInterval(duration)
    }

    /// Whether a watcher event observed `at` this moment should be
    /// suppressed as our own echo.
    public func isExpectingWrite(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now <= expiresAt
    }

    public mutating func clear() {
        expiresAt = nil
    }
}
