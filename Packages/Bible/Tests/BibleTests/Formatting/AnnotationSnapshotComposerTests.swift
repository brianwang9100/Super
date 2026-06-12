import Foundation
import Testing
@testable import Bible

/// Tests for `AnnotationSnapshotComposer` — the pure markdown formatter
/// that fills `RecordReference.snapshot` when an annotation is added to
/// chat.
@Suite("AnnotationSnapshotComposer")
struct AnnotationSnapshotComposerTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(
        id: String = "anno-1",
        summary: String
    ) -> BibleAnnotationRecord {
        BibleAnnotationRecord(
            id: id,
            target: .verse,
            bookId: "ROM",
            chapterNumber: 8,
            verseStart: 28,
            verseEnd: 30,
            summary: summary,
            source: .user,
            modelId: "test-model",
            createdAt: now
        )
    }

    @Test("renders as citation H2 + blank line + summary + trailing newline")
    func citationHeadingThenSummary() {
        let snapshot = AnnotationSnapshotComposer.compose(
            annotation: record(summary: "Paul, writing from Rome."),
            citation: "Romans 8:28-30"
        )
        #expect(snapshot == "## Romans 8:28-30 — annotation\n\nPaul, writing from Rome.\n")
    }

    @Test("the stored summary's own markdown passes through verbatim")
    func summaryMarkdownPreserved() {
        let summary = "### The golden chain\n\n**Foreknew** → glorified.\n\n> Romans 8:28-30"
        let snapshot = AnnotationSnapshotComposer.compose(
            annotation: record(summary: summary),
            citation: "Romans 8:28-30"
        )
        #expect(snapshot == "## Romans 8:28-30 — annotation\n\n\(summary)\n")
    }

    @Test("snapshot is deterministic for the same input")
    func deterministic() {
        let card = record(summary: "Paul.")
        let first = AnnotationSnapshotComposer.compose(annotation: card, citation: "Romans 8")
        let second = AnnotationSnapshotComposer.compose(annotation: card, citation: "Romans 8")
        #expect(first == second)
    }
}
