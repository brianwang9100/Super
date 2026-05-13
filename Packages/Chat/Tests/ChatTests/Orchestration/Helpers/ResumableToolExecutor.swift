import Core
import Foundation

/// A `ToolExecutor` that blocks on `execute(...)` until the test calls
/// `resume(with:)`, modeling a slow remote tool. Used by tests that need
/// a deterministic mid-turn pause — the `awaitFirstCall()` signal lets a
/// test synchronize on "the tool has started running" so it can attach a
/// late subscriber or swap a view model with confidence the session is
/// in a known state.
final class ResumableToolExecutor: ToolExecutor, Sendable {
    let toolID: String
    private let state: ResumableToolState

    init(toolID: String) {
        self.toolID = toolID
        self.state = ResumableToolState()
    }

    func awaitFirstCall() async {
        await state.awaitFirstCall()
    }

    func resume(with result: ToolResult) async {
        await state.resume(with: result)
    }

    func execute(input: [String: JSONValue]) async throws -> ToolResult {
        await state.signalCalled()
        return await state.awaitResume()
    }
}

private actor ResumableToolState {
    private var hasBeenCalled = false
    private var callWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiter: CheckedContinuation<ToolResult, Never>?
    private var pendingResume: ToolResult?

    func signalCalled() {
        hasBeenCalled = true
        for w in callWaiters { w.resume() }
        callWaiters.removeAll()
    }

    func awaitFirstCall() async {
        if hasBeenCalled { return }
        await withCheckedContinuation { cont in
            callWaiters.append(cont)
        }
    }

    func resume(with result: ToolResult) {
        if let waiter = resumeWaiter {
            resumeWaiter = nil
            waiter.resume(returning: result)
        } else {
            pendingResume = result
        }
    }

    func awaitResume() async -> ToolResult {
        if let pending = pendingResume {
            pendingResume = nil
            return pending
        }
        return await withCheckedContinuation { cont in
            resumeWaiter = cont
        }
    }
}
