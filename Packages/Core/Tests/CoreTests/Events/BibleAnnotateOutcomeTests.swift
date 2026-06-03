import Foundation
import Testing
@testable import Core

/// Tests for `BibleAnnotateOutcome` — the rich generator result and its
/// `asResult` flattening to the bus/UI-facing `BibleAnnotateResult`. The
/// flattening is load-bearing: it keeps the `bibleAnnotateCompleted` event
/// payload unchanged while the classification feeds the bulk runner's circuit
/// breaker.
@Suite("BibleAnnotateOutcome")
struct BibleAnnotateOutcomeTests {
    @Test("success flattens to a success result with the same count")
    func successFlattens() {
        #expect(BibleAnnotateOutcome.success(annotationCount: 3).asResult == .success(annotationCount: 3))
        // Zero is a valid success and must survive the flatten unchanged.
        #expect(BibleAnnotateOutcome.success(annotationCount: 0).asResult == .success(annotationCount: 0))
    }

    @Test("failure flattens to a failure result carrying the message, dropping classification")
    func failureFlattensDroppingClassification() {
        for classification: BibleAnnotateFailure in [.retryable, .fatalAuth, .fatalQuota] {
            let outcome = BibleAnnotateOutcome.failure(message: "boom", classification: classification)
            #expect(outcome.asResult == .failure(message: "boom"))
        }
    }

    @Test("equality distinguishes the classification")
    func equalityDistinguishesClassification() {
        // Same message, different classification → not equal (the runner relies
        // on this to tell a fatal halt from a retryable unit failure).
        #expect(
            BibleAnnotateOutcome.failure(message: "x", classification: .fatalAuth)
                != .failure(message: "x", classification: .fatalQuota)
        )
        #expect(
            BibleAnnotateOutcome.failure(message: "x", classification: .retryable)
                == .failure(message: "x", classification: .retryable)
        )
    }
}
