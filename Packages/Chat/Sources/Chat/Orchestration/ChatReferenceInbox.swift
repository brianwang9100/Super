import Core
import Observation

/// An ordered reference handoff for the current composer or a new conversation.
public struct ComposerAttentionRequest: Sendable, Equatable {
    /// Whether to create a conversation before attaching this batch.
    public let startNew: Bool
    /// References owned by this request, never drained by an unrelated composer.
    public let references: [RecordReference]

    /// Creates a destination-bound reference batch.
    public init(startNew: Bool, references: [RecordReference]) {
        self.startNew = startNew
        self.references = references
    }
}

/// Applet-level holder for cross-applet record references handed to Chat
/// (Bible verse ranges today). Lives for the whole app session — owned by
/// the shell, not the per-conversation `ChatScreenViewModel` — so a
/// reference added while the chat screen is unmounted is still delivered
/// when the shell processes the queued handoff.
///
/// `attach(to:)` subscribes to the `SuperEventBus` once. The bus itself is
/// fire-and-forget, so this buffer is what makes delivery guaranteed.
@MainActor
@Observable
public final class ChatReferenceInbox {
    private var requests: [ComposerAttentionRequest] = []

    /// Changes on every handoff, including identical events between view updates.
    /// The shell observes this signal and drains all queued requests in order.
    public private(set) var attentionRevision: UInt64 = 0

    private var subscriptionTask: Task<Void, Never>?
    /// One-shot callbacks fired after the next processed event — the
    /// `_onNextEvent` test seam. Not observed in production.
    private var eventCallbacks: [@MainActor () -> Void] = []

    /// Creates an empty session-scoped inbox.
    public init() {}

    // No `deinit` cancel: the inbox is shell-owned and lives for the whole
    // app session, and the subscription task holds `self` weakly so it
    // unwinds on its own if the inbox ever is released.

    /// Subscribe to the bus. Awaiting this guarantees the subscription is
    /// registered with the bus before it returns, so an event published
    /// afterward is delivered. Idempotent — a second call is a no-op, so
    /// the shell can call it unconditionally after bootstrap.
    public func attach(to bus: SuperEventBus) async {
        guard subscriptionTask == nil else { return }
        let stream = await bus.events()
        subscriptionTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    /// Remove the oldest complete composer-attention request, returning
    /// `nil` when there's nothing to act on.
    public func consumeAttention() -> ComposerAttentionRequest? {
        guard !requests.isEmpty else { return nil }
        return requests.removeFirst()
    }

    private func handle(_ event: SuperEvent) {
        if case .recordAddedToChat(let reference, let startNew) = event {
            if let last = requests.last, last.startNew == startNew {
                var references = last.references
                if !references.contains(where: { $0.id == reference.id }) {
                    references.append(reference)
                }
                requests[requests.count - 1] = ComposerAttentionRequest(startNew: startNew, references: references)
            } else {
                requests.append(ComposerAttentionRequest(startNew: startNew, references: [reference]))
            }
            attentionRevision &+= 1
        }
        let callbacks = eventCallbacks
        eventCallbacks.removeAll()
        for callback in callbacks { callback() }
    }

    /// Test seam: register a one-shot callback fired after the inbox
    /// processes its next bus event. Registration is synchronous so a
    /// test can arm it before publishing, with no race.
    func _onNextEvent(_ callback: @escaping @MainActor () -> Void) {
        eventCallbacks.append(callback)
    }
}
