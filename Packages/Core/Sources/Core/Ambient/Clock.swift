import Foundation
import os

/// Injectable clock abstraction. Production code receives a `Clock` instead
/// of calling `Date()` directly so tests can substitute `FixedClock` for
/// deterministic time. Per the root AGENTS.md, code that bakes in `Date()`
/// is not considered testable.
public protocol Clock: Sendable {
    /// Returns the current instant as a `Date` value.
    func now() -> Date
}

/// Real-time clock backed by `Date()`.
public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}

/// Test clock with mutable state guarded by `os_unfair_lock` (no actor hop
/// required, so `now()` stays synchronous).
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
