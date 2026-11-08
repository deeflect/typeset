import Foundation

/// Pure state machine for the M3 conflict rule (PLAN §4): while source edit
/// mode is open and the watcher reports the file changed on disk, decide
/// whether that's silent (buffer is clean) or needs the non-modal
/// "Keep mine / Take theirs" banner (buffer is dirty). Never a modal
/// dialog — the caller renders `.bannerPending` as an inline banner.
public enum EditSessionState: Equatable, Sendable {
    /// Not in edit mode, or in edit mode with no unsaved changes.
    case clean
    /// In edit mode with unsaved changes, no outstanding conflict.
    case dirty
    /// The watcher reported an external change while the buffer was dirty;
    /// waiting on the user to pick "Keep mine" or "Take theirs".
    case conflictPending
}

public enum EditSessionEvent: Equatable, Sendable {
    /// User started editing (⌘E into source mode), or made the first edit
    /// since a save/load.
    case bufferEdited
    /// Buffer was saved, or edit mode exited/discarded.
    case bufferSettled
    /// The watched file changed on disk (from `FileWatcher`).
    case externalChange
    /// User chose "Keep mine" at the conflict banner.
    case keepMine
    /// User chose "Take theirs" at the conflict banner.
    case takeTheirs
}

public enum EditSessionAction: Equatable, Sendable {
    /// No user-visible effect beyond the state transition itself.
    case none
    /// Reload the buffer from disk silently (buffer was clean).
    case silentReload
    /// Show the non-modal conflict banner.
    case showConflictBanner
    /// Dismiss the conflict banner; the buffer's own content is kept as-is
    /// (a subsequent save will overwrite disk).
    case dismissBannerKeepBuffer
    /// Dismiss the conflict banner and reload the buffer from disk,
    /// discarding the in-progress edits.
    case dismissBannerReloadBuffer
}

/// Computes the next `(state, action)` for one event. Free function (not a
/// method on a class) so it's trivially unit-testable without any
/// AppKit/watcher/IO dependency.
public enum EditConflictMachine {
    public static func transition(
        state: EditSessionState, event: EditSessionEvent
    ) -> (state: EditSessionState, action: EditSessionAction) {
        switch (state, event) {
        case (.clean, .bufferEdited):
            return (.dirty, .none)
        case (.clean, .externalChange):
            return (.clean, .silentReload)
        case (.dirty, .externalChange):
            return (.conflictPending, .showConflictBanner)
        case (.dirty, .bufferSettled):
            return (.clean, .none)
        case (.conflictPending, .keepMine):
            return (.dirty, .dismissBannerKeepBuffer)
        case (.conflictPending, .takeTheirs):
            return (.clean, .dismissBannerReloadBuffer)
        // Events that don't apply to the current state are no-ops: stay
        // put with no side effect, rather than crash/assert — a stray
        // duplicate watcher event or a save that lands mid-conflict
        // shouldn't corrupt the machine.
        case (.clean, .bufferSettled), (.clean, .keepMine), (.clean, .takeTheirs):
            return (.clean, .none)
        case (.dirty, .bufferEdited):
            return (.dirty, .none)
        case (.dirty, .keepMine), (.dirty, .takeTheirs):
            return (.dirty, .none)
        case (.conflictPending, .bufferEdited), (.conflictPending, .bufferSettled),
            (.conflictPending, .externalChange):
            return (.conflictPending, .none)
        }
    }
}
