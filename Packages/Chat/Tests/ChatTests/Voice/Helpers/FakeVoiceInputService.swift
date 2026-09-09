import Foundation
import os
@testable import Chat

/// Recognition stays open for manual emit/failNext/finish calls; each start creates a new stream.
final class FakeVoiceInputService: VoiceInputService, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var _permissionStatus: VoiceInputPermissionStatus = .granted
    private var _isAvailableValue: Bool = true
    private var _startCallCount: Int = 0
    private var continuation: AsyncThrowingStream<VoiceInputEvent, Error>.Continuation?
    private var generation = 0
    private var pendingStop: AsyncThrowingStream<VoiceInputEvent, Error>.Continuation?
    private var delaysStopCompletion = false
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

    /// Hold permission completion to stage concurrent controller toggles.
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

    // Keep lock operations in a synchronous helper for Swift 6 concurrency checking.
    private func currentGate() -> PermissionGate? {
        lock.lock()
        defer { lock.unlock() }
        return permissionGate
    }

    func startRecognition(locale: Locale) -> AsyncThrowingStream<VoiceInputEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<VoiceInputEvent, Error>.makeStream()
        lock.lock()
        _startCallCount += 1
        generation += 1
        let session = generation
        self.continuation = continuation
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            if self.generation == session { self.continuation = nil }
            self.lock.unlock()
        }
        return stream
    }

    func stopRecognition() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let delayed = delaysStopCompletion
        if delayed { pendingStop = continuation }
        lock.unlock()
        if !delayed { continuation?.finish() }
    }

    /// Hold stream completion to exercise the controller drain wait.
    func delayStopCompletion() {
        lock.lock()
        delaysStopCompletion = true
        lock.unlock()
    }

    var isCapturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation != nil
    }

    func emit(_ event: VoiceInputEvent) {
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(event)
    }

    func failNext(with error: VoiceInputError) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish(throwing: error)
    }

    /// Finish without a final event; the controller treats this as a normal stop.
    func finish() {
        lock.lock()
        let continuation = self.continuation ?? pendingStop
        self.continuation = nil
        pendingStop = nil
        lock.unlock()
        continuation?.finish()
    }
}

/// One-shot gate that releases current and future waiters.
final class PermissionGate: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        // Signal entry before parking. The released latch prevents a racing release
        // from being lost between that signal and waiter registration.
        for continuation in markEntered() { continuation.resume() }

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

    private func markEntered() -> [CheckedContinuation<Void, Never>] {
        lock.lock()
        defer { lock.unlock() }
        entered = true
        let pending = entryWaiters
        entryWaiters.removeAll()
        return pending
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if entered {
                lock.unlock()
                continuation.resume()
            } else {
                entryWaiters.append(continuation)
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
