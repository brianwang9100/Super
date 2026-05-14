import Foundation
import Testing
@testable import Chat

/// Tests for ``DictationTranscriptAccumulator``'s merging of multiple
/// recognizer utterances into a single rendered transcript. Pure value
/// type so every case runs synchronously without standing up a recognizer
/// or audio engine.
@Suite("DictationTranscriptAccumulator")
struct DictationTranscriptAccumulatorTests {
    @Test("renders empty before any input")
    func emptyAtStart() {
        let accumulator = DictationTranscriptAccumulator()
        #expect(accumulator.renderedTranscript == "")
    }

    @Test("renders the in-flight partial as-is")
    func singlePartial() {
        var accumulator = DictationTranscriptAccumulator()
        accumulator.ingestPartial("hello")
        #expect(accumulator.renderedTranscript == "hello")
    }

    @Test("a later partial replaces the earlier one within the same utterance")
    func partialReplacesEarlierPartial() {
        var accumulator = DictationTranscriptAccumulator()
        accumulator.ingestPartial("hel")
        accumulator.ingestPartial("hello")
        accumulator.ingestPartial("hello there")
        #expect(accumulator.renderedTranscript == "hello there")
    }

    @Test("committing the current utterance moves it into the joined transcript")
    func commitMovesPartialIntoTranscript() {
        var accumulator = DictationTranscriptAccumulator()
        accumulator.ingestPartial("hello")
        accumulator.commitCurrentUtterance("hello")
        #expect(accumulator.renderedTranscript == "hello")
    }

    @Test("commit then a new partial joins the two with a single space (hello -> pause -> world)")
    func commitThenNewPartialAppends() {
        var accumulator = DictationTranscriptAccumulator()
        accumulator.ingestPartial("hello")
        accumulator.commitCurrentUtterance("hello")
        accumulator.ingestPartial("world")
        #expect(accumulator.renderedTranscript == "hello world")
    }

    @Test("two commits in a row join with a single space and no trailing partial")
    func twoCommitsJoin() {
        var accumulator = DictationTranscriptAccumulator()
        accumulator.commitCurrentUtterance("hello")
        accumulator.commitCurrentUtterance("world")
        #expect(accumulator.renderedTranscript == "hello world")
    }

    @Test("whitespace around partials and commits is trimmed before merging")
    func whitespaceIsTrimmed() {
        var accumulator = DictationTranscriptAccumulator()
        accumulator.commitCurrentUtterance("  hello  ")
        accumulator.ingestPartial("   world   ")
        #expect(accumulator.renderedTranscript == "hello world")
    }

    @Test("empty commit is a no-op and does not introduce a stray separator")
    func emptyCommitIsNoOp() {
        var accumulator = DictationTranscriptAccumulator()
        accumulator.commitCurrentUtterance("hello")
        accumulator.commitCurrentUtterance("")
        accumulator.commitCurrentUtterance("   ")
        accumulator.ingestPartial("world")
        #expect(accumulator.renderedTranscript == "hello world")
    }

    @Test("empty partial clears the in-flight partial without touching commits")
    func emptyPartialClearsInFlight() {
        var accumulator = DictationTranscriptAccumulator()
        accumulator.commitCurrentUtterance("hello")
        accumulator.ingestPartial("world")
        accumulator.ingestPartial("")
        #expect(accumulator.renderedTranscript == "hello")
    }

    @Test("commit clears the in-flight partial so it isn't repeated alongside the committed utterance")
    func commitClearsInFlightPartial() {
        var accumulator = DictationTranscriptAccumulator()
        accumulator.ingestPartial("hello")
        accumulator.commitCurrentUtterance("hello world")
        #expect(accumulator.renderedTranscript == "hello world")
    }
}
