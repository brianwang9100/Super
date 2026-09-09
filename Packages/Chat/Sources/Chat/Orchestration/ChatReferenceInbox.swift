import Core
import Observation

public struct ComposerAttentionRequest: Sendable, Equatable {
    public let startNew: Bool
    public init(startNew: Bool) {
        self.startNew = startNew
    }
}

/// Shell-owned buffer preserves received references while no composer is mounted.
@MainActor
@Observable
public final class ChatReferenceInbox {
    public private(set) var pending: [RecordReference] = []

    public private(set) var pendingAttention: ComposerAttentionRequest?

    private var subscriptionTask: Task<Void, Never>?
    private var eventCallbacks: [@MainActor () -> Void] = []

    public init() {}

    /// Return after registering the bus subscription; repeated attachment is a no-op.
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

    public func drainPending() -> [RecordReference] {
        defer { pending.removeAll() }
        return pending
    }

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

    /// Register synchronously before publishing; fire once after processing the next event.
    func _onNextEvent(_ callback: @escaping @MainActor () -> Void) {
        eventCallbacks.append(callback)
    }
}
