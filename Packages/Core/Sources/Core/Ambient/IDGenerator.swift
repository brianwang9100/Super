import Foundation
import os

/// Injectable identifier generator. Lets tests assert deterministic IDs
/// instead of grappling with random UUID (Universally Unique Identifier)
/// strings.
public protocol IDGenerator: Sendable {
    /// Returns a new identifier. Implementations must produce a unique value
    /// per call within their intended lifetime.
    func nextID() -> String
}

/// Production generator producing RFC 4122 UUID strings.
public struct UUIDGenerator: IDGenerator {
    public init() {}
    public func nextID() -> String { UUID().uuidString }
}

/// Test generator yielding `<prefix><n>` where n increments from `start + 1`.
public final class DeterministicIDGenerator: IDGenerator {
    private let prefix: String
    private let counter: OSAllocatedUnfairLock<Int>

    public init(prefix: String = "id-", start: Int = 0) {
        self.prefix = prefix
        self.counter = OSAllocatedUnfairLock(initialState: start)
    }

    public func nextID() -> String {
        let next = counter.withLock { value -> Int in
            value += 1
            return value
        }
        return "\(prefix)\(next)"
    }
}
