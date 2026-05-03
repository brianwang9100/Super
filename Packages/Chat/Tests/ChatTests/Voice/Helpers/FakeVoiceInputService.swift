import Foundation
@testable import Chat

/// In-memory ``VoiceInputService`` test double. Tests configure
/// `permissionStatus` and `isAvailableValue` synchronously, then drive
/// the active recognition stream by calling `emit(_:)` /
/// `failNext(with:)` / `finish()` from the test body. Each
/// `startRecognition(locale:)` opens a fresh continuation; callers can
/// inspect `startCallCount` to assert how many sessions started.
///
/// Strict by design: failing to script the next session before
/// `startRecognition(locale:)` is fine — the stream just stays open
/// until the test calls `emit` or `finish`. Tests assert against
/// `startCallCount` to catch double-start regressions.
final class FakeVoiceInputService: VoiceInputService, @unchecked Sendable {
    private let lock = NSLock()
    private var _permissionStatus: VoiceInputPermissionStatus = .granted
    private var _isAvailableValue: Bool = true
    private var _startCallCount: Int = 0
    private var continuation: AsyncThrowingStream<VoiceInputEvent, Error>.Continuation?
    private var permissionGate: PermissionGate?

    var permissionStatus: VoiceInputPermissionStatus {
        get { lock.lock(); defer { lock.unlock() }; return _permissionStatus }
        set { lock.lock(); _permissionStatus = newValue; lock.unlock() }
    }

    var isAvailableValue: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isAvailableValue }
        set { lock.lock(); _isAvailableValue = newValue; lock.unlock() }
    }

    var startCallCount: Int {
        lock.lock(); defer { lock.unlock() }; return _startCallCount
    }

    func isAvailable(locale: Locale) -> Bool {
        isAvailableValue
    }

    /// Install a one-shot gate that suspends `requestPermissions` until
    /// the test calls `release()` on the returned gate. Lets tests stage
    /// concurrent toggles racing past the controller's `isStarting`
    /// guard while the first toggle is still awaiting permissions.
    func gatePermissions() -> PermissionGate {
        let gate = PermissionGate()
        lock.lock()
        permissionGate = gate
        lock.unlock()
        return gate
    }

    func requestPermissions() async -> VoiceInputPermissionStatus {
        if let gate = currentGate() { await gate.wait() }
        return permissionStatus
    }

    /// Synchronous read of `permissionGate` so `requestPermissions`
    /// (an async function) doesn't call `NSLock.lock/unlock` from an
    /// async context — Swift 6 strict concurrency disallows that.
    private func currentGate() -> PermissionGate? {
        lock.lock()
        defer { lock.unlock() }
        return permissionGate
    }

    func startRecognition(locale: Locale) -> AsyncThrowingStream<VoiceInputEvent, Error> {
        lock.lock()
        _startCallCount += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            self.lock.lock()
            self.continuation = continuation
            self.lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuation = nil
                self?.lock.unlock()
            }
        }
    }

    /// Yield an event into the active stream. No-op if no session is
    /// running.
    func emit(_ event: VoiceInputEvent) {
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(event)
    }

    /// Throw an error into the active stream and finish it.
    func failNext(with error: VoiceInputError) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish(throwing: error)
    }

    /// Cleanly finish the active stream without a final event. The
    /// controller treats this as a normal stop.
    func finish() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
    }
}

/// Multi-awaiter one-shot gate used by ``FakeVoiceInputService.gatePermissions``
/// to suspend `requestPermissions` until the test fires `release()`. Same
/// shape as the M10 `SleepGate` helper — every awaiter (current + future)
/// resumes the moment the gate opens.
final class PermissionGate: @unchecked Sendable {
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
