import Foundation

/// Pure trailing-edge debounce logic for the file watcher's burst of raw
/// filesystem events (a single editor save can fire several: a directory
/// write, a file write, an extend, ...). Kept independent of any real
/// timer/queue so it's unit-testable without waiting on wall-clock time —
/// `FileWatcher` drives a real `DispatchSourceTimer` rescheduled to the
/// deadline this reports.
public enum ReloadDebouncer {

    /// Given the timestamps (in any consistent time coordinate, e.g.
    /// seconds since an arbitrary epoch) of a sequence of raw events,
    /// returns the timestamps at which a coalesced reload should fire —
    /// one per "burst" of events that are each within `interval` of the
    /// previous event's own fire deadline, `interval` seconds after that
    /// burst's last event. Events must be non-decreasing (as they would be
    /// arriving in real time).
    public static func coalesce(eventTimes: [TimeInterval], interval: TimeInterval) -> [TimeInterval] {
        var fireTimes: [TimeInterval] = []
        var burstDeadline: TimeInterval?
        for time in eventTimes {
            if let deadline = burstDeadline, time <= deadline {
                burstDeadline = time + interval
            } else {
                if let deadline = burstDeadline { fireTimes.append(deadline) }
                burstDeadline = time + interval
            }
        }
        if let deadline = burstDeadline { fireTimes.append(deadline) }
        return fireTimes
    }

    /// The deadline a real timer should be (re)scheduled to after observing
    /// one more raw event at `now`, given `interval`. `FileWatcher` calls
    /// this on every raw event and reschedules its debounce timer to fire
    /// at the returned deadline, cancelling any previously scheduled one —
    /// exactly the trailing-edge behavior `coalesce` models above.
    public static func rescheduleDeadline(now: TimeInterval, interval: TimeInterval) -> TimeInterval {
        now + interval
    }
}
