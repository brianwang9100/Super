import Foundation
import Testing
@testable import Chat

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

@MainActor
private final class FlushSink {
    var flushed: [String] = []
    func append(_ chunk: String) { flushed.append(chunk) }
}
