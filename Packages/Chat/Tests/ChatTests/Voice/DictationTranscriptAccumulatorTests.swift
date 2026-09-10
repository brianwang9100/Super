import Testing
@testable import Chat

@Suite("DictationTranscriptAccumulator")
struct DictationTranscriptAccumulatorTests {
    @Test("nonempty hypotheses may refine only the pending phrase")
    func revisions() {
        var accumulator = DictationTranscriptAccumulator()
        accumulator.ingestPartial("  hello  ")
        accumulator.ingestPartial("Hello there")
        #expect(accumulator.partialTranscript == "Hello there")
        #expect(accumulator.commitCurrentUtterance("Hello there.") == "Hello there.")
        #expect(accumulator.partialTranscript.isEmpty)
        accumulator.ingestPartial("world")
        #expect(accumulator.commitCurrentUtterance() == "world")
        #expect(accumulator.commitCurrentUtterance().isEmpty)
    }

    @Test("empty callbacks at a pause cannot erase a pending phrase")
    func emptyCallbacksRetainSpeech() {
        var accumulator = DictationTranscriptAccumulator()
        accumulator.ingestPartial("hello")
        accumulator.ingestPartial("")
        accumulator.ingestPartial(" \n ")
        #expect(accumulator.partialTranscript == "hello")
        #expect(accumulator.commitCurrentUtterance("  ") == "hello")
        #expect(accumulator.commitCurrentUtterance().isEmpty)
    }

    @Test("identical phrases on opposite sides of a pause are distinct speech")
    func repeatedPhrases() {
        var accumulator = DictationTranscriptAccumulator()
        #expect(accumulator.commitCurrentUtterance("yes") == "yes")
        #expect(accumulator.commitCurrentUtterance("yes") == "yes")
    }
}
