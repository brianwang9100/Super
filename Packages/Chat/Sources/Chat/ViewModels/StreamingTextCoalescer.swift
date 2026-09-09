import Foundation

/// Batch deltas to avoid reparsing Markdown per token. Flush at trailing whitespace
/// or a deadline, whichever comes first.
@MainActor
final class StreamingTextCoalescer {
    private var pendingText: String = ""
    private var flushTask: Task<Void, Never>?
    private let interval: Duration
    private let sleep: @Sendable (Duration) async -> Void
    var onFlush: @MainActor (String) -> Void = { _ in }

    init(
        interval: Duration = .milliseconds(100),
        sleep: (@Sendable (Duration) async -> Void)? = nil
    ) {
        self.interval = interval
        // The timer checks cancellation after this nonthrowing sleep.
        self.sleep = sleep ?? { try? await Task.sleep(for: $0) }
    }

    func append(_ chunk: String) {
        pendingText += chunk
        // Only the visible tail signals a completed word.
        if chunk.last?.isWhitespace == true {
            flush()
            return
        }
        scheduleFlushIfNeeded()
    }

    /// Publish the final buffered frame before the host removes the streaming overlay.
    func flush() {
        flushTask?.cancel()
        flushTask = nil
        drain()
    }

    /// Discard unpublished text when detaching or starting a different turn.
    func reset() {
        flushTask?.cancel()
        flushTask = nil
        pendingText = ""
    }

    var _pendingText: String { pendingText }

    func _waitForPendingFlushTask() async {
        await flushTask?.value
    }

    private func scheduleFlushIfNeeded() {
        guard flushTask == nil else { return }
        let sleep = self.sleep
        let interval = self.interval
        flushTask = Task { @MainActor [weak self] in
            await sleep(interval)
            if Task.isCancelled { return }
            guard let self else { return }
            self.flushTask = nil
            self.drain()
        }
    }

    private func drain() {
        if pendingText.isEmpty { return }
        let chunk = pendingText
        pendingText = ""
        onFlush(chunk)
    }
}
