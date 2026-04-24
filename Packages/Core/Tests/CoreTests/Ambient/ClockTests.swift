import Testing
import Foundation
@testable import Core

/// Tests for `SystemClock` and the deterministic `FixedClock`.
@Suite("Clock")
struct ClockTests {
    @Test func systemClockReturnsRecentNow() {
        let before = Date()
        let now = SystemClock().now()
        let after = Date()
        #expect(now >= before)
        #expect(now <= after)
    }

    @Test func fixedClockHoldsInitialValue() {
        let date = Date(timeIntervalSince1970: 1_000)
        let clock = FixedClock(date)
        #expect(clock.now() == date)
    }

    @Test func fixedClockAdvances() {
        let clock = FixedClock(Date(timeIntervalSince1970: 0))
        clock.advance(by: 60)
        #expect(clock.now() == Date(timeIntervalSince1970: 60))
        clock.advance(by: 30)
        #expect(clock.now() == Date(timeIntervalSince1970: 90))
    }

    @Test func fixedClockSetReplacesValue() {
        let clock = FixedClock(Date(timeIntervalSince1970: 0))
        let target = Date(timeIntervalSince1970: 5_000)
        clock.set(target)
        #expect(clock.now() == target)
    }
}
