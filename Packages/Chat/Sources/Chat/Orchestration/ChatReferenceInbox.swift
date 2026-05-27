import Core
import Observation

/// Applet-level holder for cross-applet record references handed to Chat
/// (Bible verse ranges today). Lives for the whole app session — owned by
/// the shell, not the per-conversation `ChatScreenViewModel` — so a
/// reference added while the chat screen is unmounted is still delivered
/// when a composer next mounts and drains it.
///
/// `attach(to:)` subscribes to the `SuperEventBus` once. The bus itself is
/// fire-and-forget, so this buffer is what makes delivery guaranteed.
@MainActor
@Observable
public final class ChatReferenceInbox {
    /// References waiting to be shown in a composer. The mounted
    /// `ChatScreenViewModel` drains these via `drainPending()`.
    public private(set) var pending: [RecordReference] = []

    /// Set when a `.recordAddedToChat(startNewConversation: true)` event
    /// arrives. The shell observes this to start a fresh conversation,
    /// then clears it via `consumeNewConversationRequest()`.
    public private(set) var wantsNewConversation = false

    /// Set on every `.recordAddedToChat` event regardless of
    /// `startNewConversation`. The shell observes this as the single
    /// "Bible just handed a reference to chat" signal and dispatches the
    /// chrome change (semi-expand from minimized) plus composer focus.
    /// Separate from ``wantsNewConversation`` so the new-chat case and
    /// the add-to-existing case share one observer instead of racing.
    public private(set) var wantsComposerAttention = false

    private var subscriptionTask: Task<Void, Never>?
    /// One-shot callbacks fired after the next processed event — the
    /// `_onNextEvent` test seam. Not observed in production.
    private var eventCallbacks: [@MainActor () -> Void] = []

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

    /// Move every pending reference out for a composer to adopt, leaving
    /// the inbox empty.
    public func drainPending() -> [RecordReference] {
        defer { pending.removeAll() }
        return pending
    }

    /// Read and clear the new-conversation request flag.
    public func consumeNewConversationRequest() -> Bool {
        defer { wantsNewConversation = false }
        return wantsNewConversation
    }

    /// Read and clear the composer-attention request flag.
    public func consumeAttentionRequest() -> Bool {
        defer { wantsComposerAttention = false }
        return wantsComposerAttention
    }

    private func handle(_ event: SuperEvent) {
        if case .recordAddedToChat(let reference, let startNew) = event {
            pending.append(reference)
            wantsComposerAttention = true
            if startNew { wantsNewConversation = true }
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
