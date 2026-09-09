import Foundation

/// Broadcasts only to active subscribers; events sent before events() are not buffered.
/// Long-lived receivers buffer pending work themselves. The shell uses one subscriber
/// and OrderedInbox to preserve order across reference handoffs and navigation.
public actor SuperEventBus {
    private var continuations: [UUID: AsyncStream<SuperEvent>.Continuation] = [:]

    public init() {}

    /// Yield `event` to every active subscriber. Subscribers added after
    /// this call do not see it.
    public func publish(_ event: SuperEvent) {
        for (_, continuation) in continuations {
            continuation.yield(event)
        }
    }

    /// A fresh stream of every event published after this call. The
    /// subscriber is removed automatically when the returned stream's
    /// iterator is released (or the consuming task is cancelled).
    public func events() -> AsyncStream<SuperEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SuperEvent>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id: id) }
        }
        return stream
    }

    /// Number of active subscribers — exposed for tests asserting cleanup.
    public var subscriberCount: Int {
        continuations.count
    }

    private func removeSubscriber(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
