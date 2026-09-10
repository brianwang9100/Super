import Foundation
import Synchronization

/// One-shot barrier for injected sleep closures. Opening releases current
/// waiters and lets future callers pass immediately.
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
