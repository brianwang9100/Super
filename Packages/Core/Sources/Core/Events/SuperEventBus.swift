import Foundation

/// In-process broadcast bus for cross-applet `SuperEvent`s. Built once at
/// the composition root and injected into every applet via SwiftUI
/// `@Environment`. Bidirectional by shape — any applet may publish and any
/// may subscribe — though only the record-to-chat hand-off is wired today.
///
/// Delivery is fire-and-forget: an event published before a subscriber
/// calls `events()` is not buffered for it. A receiver that must not miss
/// an event keeps a long-lived subscriber and buffers pending payloads
/// itself — see `ChatReferenceInbox` in the Chat applet.
///
/// The fan-out mirrors `ChatSession`'s per-turn subscriber map: a
/// `[UUID: Continuation]` dictionary, with `onTermination` removing a
/// subscriber once its stream iterator is released.
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
