/// Serializes complete main-actor actions, including their suspension points.
/// Actions may enqueue more work, but must not await that later work from inside
/// the same lane: it cannot start until its predecessor finishes.
@MainActor
public final class SerialActionQueue {
    private var tail: Task<Void, Never>?
    private var pendingCount = 0

    /// Whether an action is executing or waiting, reserved before enqueue returns.
    public var isBusy: Bool { pendingCount > 0 }

    /// Creates an empty action queue.
    public init() {}

    /// Reserves a place in the lane and returns a task for joining this action.
    /// The entire predecessor finishes before the action starts. Work is not
    /// superseded or rolled back; callers should await the handle rather than
    /// cancel it to implement navigation replacement.
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

    /// Runs synchronous work inline when idle, retaining the caller's transaction.
    /// While busy, returns a task that joins this action after all earlier work.
    /// A nil result means the action already completed inline.
    @discardableResult
    public func enqueueSynchronous(_ action: @escaping @MainActor @Sendable () -> Void) -> Task<Void, Never>? {
        guard !isBusy else { return enqueue { action() } }
        // Reserve during the callback too, so reentrant submissions queue instead
        // of executing inside a partially completed synchronous action.
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
