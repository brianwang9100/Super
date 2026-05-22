import Foundation
import Synchronization

/// One-shot gate that suspends `wait()` callers until `release()` opens
/// it, then resumes every awaiter (current and future). Used by tests
/// that inject a sleep closure into a `Task`-managed timer so the body
/// pauses on a deterministic signal rather than a real-clock duration —
/// see `CodeBlockCopyControllerTests` and `StreamingTextCoalescerTests`
/// for the call sites.
///
/// Sleep is what most callers want; the gate also serves as a stop-the-
/// world barrier for any closure-shaped suspension point.
///
/// State is protected by ``Synchronization/Mutex`` per AGENTS.md
/// §Swift Concurrency ("Never use `DispatchQueue` or `NSLock` for
/// synchronization"). A `Mutex<State>` makes the class straightforwardly
/// `Sendable` without `@unchecked`.
final class SleepGate: Sendable {
    private let state = Mutex(State())

    private struct State {
        var continuations: [CheckedContinuation<Void, Never>] = []
        var released = false
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if state.released {
                    return true
                }
                state.continuations.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func release() {
        let pending = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            let pending = state.continuations
            state.continuations.removeAll()
            state.released = true
            return pending
        }
        for continuation in pending { continuation.resume() }
    }
}
