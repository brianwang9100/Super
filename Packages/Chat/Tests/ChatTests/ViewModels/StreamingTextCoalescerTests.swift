import Foundation
import Testing
@testable import Chat

/// Tests for ``StreamingTextCoalescer``'s flush policy: buffer
/// non-whitespace chunks behind a 100ms timer, flush immediately when
/// a chunk's tail is whitespace, force-flush on demand, and discard the
/// buffer on reset.
///
/// All tests inject a ``SleepGate``-backed sleep so the ceiling timer
/// waits for an explicit `release()` before firing — no real-clock
/// timing in the assertions, deterministic ordering through awaitable
/// signals as ``AGENTS.md`` §Testing.2 requires.
@Suite("StreamingTextCoalescer")
@MainActor
struct StreamingTextCoalescerTests {
    private func makeCoalescer(
        gate: SleepGate,
        sink: FlushSink
    ) -> StreamingTextCoalescer {
        let coalescer = StreamingTextCoalescer(
            interval: .milliseconds(100),
            sleep: { _ in await gate.wait() }
        )
        coalescer.onFlush = { chunk in sink.append(chunk) }
        return coalescer
    }

    @Test("chunk ending in whitespace flushes immediately")
    func whitespaceTailFlushesImmediately() async {
        let gate = SleepGate()
        let sink = FlushSink()
        let coalescer = makeCoalescer(gate: gate, sink: sink)

        coalescer.append("hello ")

        #expect(sink.flushed == ["hello "])
        #expect(coalescer._pendingText.isEmpty)
    }

    @Test("chunk ending in a newline flushes immediately")
    func newlineTailFlushesImmediately() async {
        let gate = SleepGate()
        let sink = FlushSink()
        let coalescer = makeCoalescer(gate: gate, sink: sink)

        coalescer.append("line one\n")

        #expect(sink.flushed == ["line one\n"])
    }

    @Test("non-whitespace deltas buffer until the timer fires")
    func nonWhitespaceDefersUntilTimer() async {
        let gate = SleepGate()
        let sink = FlushSink()
        let coalescer = makeCoalescer(gate: gate, sink: sink)

        coalescer.append("Hel")
        coalescer.append("lo")

        #expect(sink.flushed.isEmpty)
        #expect(coalescer._pendingText == "Hello")

        gate.release()
        await coalescer._waitForPendingFlushTask()

        #expect(sink.flushed == ["Hello"])
        #expect(coalescer._pendingText.isEmpty)
    }

    @Test("force flush drains immediately and prevents a stale timer wake")
    func forceFlushDrainsAndCancelsTimer() async {
        let gate = SleepGate()
        let sink = FlushSink()
        let coalescer = makeCoalescer(gate: gate, sink: sink)

        coalescer.append("partial")
        coalescer.flush()

        #expect(sink.flushed == ["partial"])
        #expect(coalescer._pendingText.isEmpty)

        // Releasing the gate must NOT trigger a second flush; the force
        // flush already cancelled the timer.
        gate.release()
        await coalescer._waitForPendingFlushTask()
        #expect(sink.flushed == ["partial"])
    }

    @Test("reset discards the buffer without publishing")
    func resetDiscardsBufferWithoutPublishing() async {
        let gate = SleepGate()
        let sink = FlushSink()
        let coalescer = makeCoalescer(gate: gate, sink: sink)

        coalescer.append("dropped")
        coalescer.reset()

        #expect(sink.flushed.isEmpty)
        #expect(coalescer._pendingText.isEmpty)

        gate.release()
        await coalescer._waitForPendingFlushTask()
        #expect(sink.flushed.isEmpty)
    }

    @Test("after a flush the next non-whitespace delta schedules a fresh timer")
    func flushResetsForNextCycle() async {
        let gate = SleepGate()
        let sink = FlushSink()
        let coalescer = makeCoalescer(gate: gate, sink: sink)

        coalescer.append("first ")
        #expect(sink.flushed == ["first "])

        coalescer.append("second")
        #expect(sink.flushed == ["first "])
        #expect(coalescer._pendingText == "second")

        gate.release()
        await coalescer._waitForPendingFlushTask()
        #expect(sink.flushed == ["first ", "second"])
    }
}

/// Main-actor-isolated sink for the flush callback so assertions can
/// inspect the published chunks without worrying about cross-actor
/// reads.
@MainActor
private final class FlushSink {
    var flushed: [String] = []
    func append(_ chunk: String) { flushed.append(chunk) }
}
