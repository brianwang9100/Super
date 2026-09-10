/// Serializes complete main-actor actions, including their suspension points.
/// Actions may enqueue more work, but must not await that later work from inside
/// the same lane: it cannot start until its predecessor finishes.
@MainActor
public final class SerialActionQueue {
    private var tail: Task<Void, Never>?
    private var pendingCount = 0

    /// Becomes true synchronously when an action reserves the lane.
    public var isBusy: Bool { pendingCount > 0 }

    public init() {}

    /// Returns a join handle; cancelling it is not a supported replacement mechanism.
    @discardableResult
    public func enqueue(_ action: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        let predecessor = tail
        pendingCount += 1
        let task = Task { @MainActor in
            await predecessor?.value
            defer { finishAction() }
            await action()
        }
        tail = task
        return task
    }

    /// Runs inline when idle; otherwise returns a handle for the queued action.
    @discardableResult
    public func enqueueSynchronous(_ action: @escaping @MainActor @Sendable () -> Void) -> Task<Void, Never>? {
        guard !isBusy else { return enqueue { action() } }
        // Reserve before the callback so reentrant submissions queue behind it.
        pendingCount += 1
        defer { finishAction() }
        action()
        return nil
    }

    private func finishAction() {
        pendingCount -= 1
        if pendingCount == 0 {
            tail = nil
        }
    }
}
