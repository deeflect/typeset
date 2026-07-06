import Foundation
import Testing
@testable import MarcoCore

struct ExpectedWriteTests {

    @Test func freshWindowDoesNotExpectAWrite() {
        let window = ExpectedWriteWindow()
        #expect(window.isExpectingWrite(at: Date()) == false)
    }

    @Test func withinDurationIsExpectingWrite() {
        var window = ExpectedWriteWindow()
        let start = Date()
        window.beginExpecting(now: start, duration: 2.0)
        #expect(window.isExpectingWrite(at: start.addingTimeInterval(1.0)))
    }

    @Test func afterDurationNoLongerExpectingWrite() {
        var window = ExpectedWriteWindow()
        let start = Date()
        window.beginExpecting(now: start, duration: 2.0)
        #expect(window.isExpectingWrite(at: start.addingTimeInterval(2.5)) == false)
    }

    @Test func clearImmediatelyStopsExpecting() {
        var window = ExpectedWriteWindow()
        let start = Date()
        window.beginExpecting(now: start, duration: 2.0)
        window.clear()
        #expect(window.isExpectingWrite(at: start) == false)
    }
}
