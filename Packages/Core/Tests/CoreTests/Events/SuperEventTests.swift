import Foundation
import Testing
@testable import Core

/// Tests for the new headless-dispatch envelopes added alongside the
/// existing cross-applet events — `bibleAnnotateRequested` and
/// `bibleAnnotateCompleted` plus the `BibleAnnotateResult` payload they
/// carry. The existing cases are covered through `SuperEventBusTests`.
@Suite("SuperEvent — Bible annotate envelopes")
struct SuperEventTests {
    @Test("two bibleAnnotateRequested events with the same reference compare equal")
    func annotateRequestedEquality() {
        let reference = RecordReference(
            appletID: "bible",
            kind: "verseRange",
            sourceID: "verse:ROM:8:28:30",
            displayLabel: "Romans 8:28-30",
            citation: "Romans 8:28-30 (WEB)",
            snapshot: "We know that all things work together…",
            id: "req-1"
        )
        let a = SuperEvent.bibleAnnotateRequested(reference: reference)
        let b = SuperEvent.bibleAnnotateRequested(reference: reference)
        #expect(a == b)
    }

    @Test("bibleAnnotateCompleted distinguishes success from failure by associated value")
    func annotateCompletedEquality() {
        let success = SuperEvent.bibleAnnotateCompleted(
            requestId: "req-1",
            result: .success(annotationCount: 3)
        )
        let sameSuccess = SuperEvent.bibleAnnotateCompleted(
            requestId: "req-1",
            result: .success(annotationCount: 3)
        )
        let differentCount = SuperEvent.bibleAnnotateCompleted(
            requestId: "req-1",
            result: .success(annotationCount: 4)
        )
        let failure = SuperEvent.bibleAnnotateCompleted(
            requestId: "req-1",
            result: .failure(message: "no key configured")
        )

        #expect(success == sameSuccess)
        #expect(success != differentCount)
        #expect(success != failure)
    }

    @Test("BibleAnnotateResult equality matches the case + payload")
    func resultEquality() {
        #expect(BibleAnnotateResult.success(annotationCount: 0) == .success(annotationCount: 0))
        #expect(BibleAnnotateResult.success(annotationCount: 1) != .success(annotationCount: 2))
        #expect(BibleAnnotateResult.failure(message: "x") == .failure(message: "x"))
        #expect(BibleAnnotateResult.failure(message: "x") != .failure(message: "y"))
        #expect(BibleAnnotateResult.success(annotationCount: 0) != .failure(message: "x"))
    }
}
