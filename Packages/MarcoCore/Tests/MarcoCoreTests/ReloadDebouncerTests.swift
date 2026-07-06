import Foundation
import Testing
@testable import MarcoCore

struct ReloadDebouncerTests {

    @Test func singleEventProducesOneFireAtIntervalAfterIt() {
        let fires = ReloadDebouncer.coalesce(eventTimes: [0.0], interval: 0.08)
        #expect(fires == [0.08])
    }

    @Test func burstOfEventsWithinIntervalCoalescesToOneFire() {
        // Events at 0, 0.02, 0.05 are each within 0.08 of the *previous*
        // event's own deadline, so they all belong to one burst; the fire
        // should land 0.08 after the LAST event in the burst.
        let fires = ReloadDebouncer.coalesce(eventTimes: [0.0, 0.02, 0.05], interval: 0.08)
        #expect(fires == [0.13])
    }

    @Test func eventsFartherApartThanIntervalProduceSeparateFires() {
        let fires = ReloadDebouncer.coalesce(eventTimes: [0.0, 0.5], interval: 0.08)
        #expect(fires == [0.08, 0.58])
    }

    @Test func emptyEventsProduceNoFires() {
        #expect(ReloadDebouncer.coalesce(eventTimes: [], interval: 0.08).isEmpty)
    }

    @Test func rescheduleDeadlineIsAlwaysNowPlusInterval() {
        #expect(ReloadDebouncer.rescheduleDeadline(now: 10.0, interval: 0.08) == 10.08)
    }
}
