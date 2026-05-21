import Foundation

/// One-shot gate that suspends `wait()` callers until `release()` opens
/// it, then resumes every awaiter (current and future). Used by tests
/// that inject a sleep closure into a `Task`-managed timer so the body
/// pauses on a deterministic signal rather than a real-clock duration —
/// see `CodeBlockCopyControllerTests` and `StreamingTextCoalescerTests`
/// for the call sites.
///
/// Sleep is what most callers want; the gate also serves as a stop-the-
/// world barrier for any closure-shaped suspension point.
final class SleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        let pending = continuations
        continuations.removeAll()
        released = true
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }
}
