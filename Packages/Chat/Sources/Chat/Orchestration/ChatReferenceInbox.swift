import Core
import Observation

/// Carries the shell's "Bible just handed a reference to chat" intent —
/// the single observable signal `AppShell` reads to semi-expand the chat
/// overlay from minimized and focus the composer. `startNew` decides
/// whether the dispatch lands in a fresh conversation or the current one.
public struct ComposerAttentionRequest: Sendable, Equatable {
    public let startNew: Bool
    public init(startNew: Bool) {
        self.startNew = startNew
    }
}

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

    /// The latest unconsumed composer-attention request from a Bible →
    /// Chat hand-off, or `nil` if there's nothing to react to. The shell
    /// observes this as a single signal and reads `startNew` to pick the
    /// dispatch path; one observable replaces the prior two-flag /
    /// two-consume dance and makes "attention is requested" + "new chat is
    /// requested" a compile-checked invariant rather than a convention.
    public private(set) var pendingAttention: ComposerAttentionRequest?

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

    /// Read and clear the pending composer-attention request, returning
    /// `nil` when there's nothing to act on.
    public func consumeAttention() -> ComposerAttentionRequest? {
        defer { pendingAttention = nil }
        return pendingAttention
    }

    private func handle(_ event: SuperEvent) {
        if case .recordAddedToChat(let reference, let startNew) = event {
            pending.append(reference)
            pendingAttention = ComposerAttentionRequest(startNew: startNew)
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
