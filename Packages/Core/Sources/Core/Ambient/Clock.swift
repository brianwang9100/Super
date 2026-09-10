import Foundation
import os

public protocol Clock: Sendable {
    func now() -> Date
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}

/// Locking keeps mutable test time safe while allowing synchronous `now()` calls.
public final class FixedClock: Clock {
    private let state: OSAllocatedUnfairLock<Date>

    public init(_ initial: Date = Date(timeIntervalSince1970: 0)) {
        self.state = OSAllocatedUnfairLock(initialState: initial)
    }

    public func now() -> Date {
        state.withLock { $0 }
    }

    public func set(_ date: Date) {
        state.withLock { $0 = date }
    }

    public func advance(by seconds: TimeInterval) {
        state.withLock { $0.addTimeInterval(seconds) }
    }
}
