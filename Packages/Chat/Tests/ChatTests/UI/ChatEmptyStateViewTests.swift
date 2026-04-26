import Foundation
import Testing
@testable import Chat

/// Greeting derivation for `ChatEmptyStateView`. Pure function on the
/// current `Date`; tests cover all four time-of-day branches.
@Suite("ChatEmptyStateView greeting")
struct ChatEmptyStateViewGreetingTests {
    private func date(hour: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 4
        components.day = 25
        components.hour = hour
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    @Test("late-night hour says tonight")
    func lateNight() {
        let calendar = Calendar(identifier: .gregorian)
        var c = calendar
        c.timeZone = TimeZone(identifier: "UTC")!
        let greeting = ChatEmptyStateView.greeting(for: date(hour: 2), calendar: c)
        #expect(greeting == "How can I help you tonight?")
    }

    @Test("morning hour says morning")
    func morning() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        let greeting = ChatEmptyStateView.greeting(for: date(hour: 9), calendar: c)
        #expect(greeting == "How can I help you this morning?")
    }

    @Test("afternoon hour says afternoon")
    func afternoon() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        let greeting = ChatEmptyStateView.greeting(for: date(hour: 14), calendar: c)
        #expect(greeting == "How can I help you this afternoon?")
    }

    @Test("evening hour says evening")
    func evening() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        let greeting = ChatEmptyStateView.greeting(for: date(hour: 19), calendar: c)
        #expect(greeting == "How can I help you this evening?")
    }

    @Test("late-evening rolls back to tonight")
    func lateEvening() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        let greeting = ChatEmptyStateView.greeting(for: date(hour: 22), calendar: c)
        #expect(greeting == "How can I help you tonight?")
    }

    @Test("boundary at 5 AM flips morning")
    func boundaryFiveAM() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        let greeting = ChatEmptyStateView.greeting(for: date(hour: 5), calendar: c)
        #expect(greeting == "How can I help you this morning?")
    }

    @Test("boundary at 17:00 flips evening")
    func boundaryFivePM() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        let greeting = ChatEmptyStateView.greeting(for: date(hour: 17), calendar: c)
        #expect(greeting == "How can I help you this evening?")
    }
}
