import Foundation

/// Decouples the per-SSE-delta text-arrival rate from the rate at which
/// `streamingTail.text` repaints. ``StreamingTail`` renders MarkdownUI
/// (Markdown is reparsed per render), so reparsing on every delta would
/// walk the entire AST tens of times per second on a fast model.
///
/// Policy: flush as soon as a chunk's tail is whitespace (a "word just
/// finished" cue — the most natural place to repaint), and otherwise
/// drain at most every ``interval`` so a burst of long-word characters
/// still repaints at a predictable rate. Sleep is injected via a closure
/// so tests substitute a ``SleepGate`` and assert deterministically
/// without real-clock waits.
///
/// Owned by ``ChatScreenViewModel``. Each scheduled drain checks
/// `Task.isCancelled` after the sleep so an explicit ``flush()`` or
/// ``reset()`` cancels the in-flight timer before a stale wake fires
/// against torn-down state — the same pattern as
/// ``CodeBlockCopyController``.
@MainActor
final class StreamingTextCoalescer {
    /// Buffered chunks waiting for the next flush. Reset to empty on
    /// every flush and on ``reset()``.
    private var pendingText: String = ""
    /// Deadline timer for the buffered-text ceiling. Held so the timer
    /// can be cancelled by a whitespace-driven flush, a force flush, or
    /// a reset before its body fires.
    private var flushTask: Task<Void, Never>?
    private let interval: Duration
    private let sleep: @Sendable (Duration) async -> Void
    /// Invoked whenever a flush drains buffered characters. Receives the
    /// full buffered chunk for the host to append to its visible state.
    /// Settable so a host whose `init` can't reference `self` until all
    /// stored properties are assigned can wire the callback as a second
    /// step. Defaults to a no-op so an unwired coalescer is harmless.
    var onFlush: @MainActor (String) -> Void = { _ in }

    init(
        interval: Duration = .milliseconds(100),
        sleep: (@Sendable (Duration) async -> Void)? = nil
    ) {
        self.interval = interval
        // Default swallows the cancellation throw — the timer task also
        // checks `Task.isCancelled` after the sleep, so a clean cancel
        // exits without flushing.
        self.sleep = sleep ?? { try? await Task.sleep(for: $0) }
    }

    /// Append a streaming chunk. Flushes immediately if the chunk's
    /// tail is whitespace; otherwise schedules a ceiling-timer flush if
    /// one isn't already pending.
    func append(_ chunk: String) {
        pendingText += chunk
        // Checking just the tail character matches the "word just
        // finished" intent — internal whitespace doesn't signal a fresh
        // word boundary at the *visible* edge.
        if chunk.last?.isWhitespace == true {
            flush()
            return
        }
        scheduleFlushIfNeeded()
    }

    /// Force-drain the buffer and cancel any pending timer. Called by
    /// the host on terminal events (`.assistantMessageSaved`,
    /// stream-end) so the last partial frame lands before the overlay
    /// tears down.
    func flush() {
        flushTask?.cancel()
        flushTask = nil
        drain()
    }

    /// Discard the buffer without publishing. Called by the host on
    /// turn-start and detach so a new turn doesn't inherit characters
    /// from a previous in-flight cycle.
    func reset() {
        flushTask?.cancel()
        flushTask = nil
        pendingText = ""
    }

    /// Test seam: read the current buffer without publishing.
    var _pendingText: String { pendingText }

    /// Test seam: await the in-flight flush task so tests synchronize
    /// on "the deferred flush ran" without polling.
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
