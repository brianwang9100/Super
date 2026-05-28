import Foundation
import Testing
@testable import Bible

/// Tests for `AnnotationSnapshotComposer` — the pure markdown formatter
/// that fills `RecordReference.snapshot` when annotations are added to
/// chat.
@Suite("AnnotationSnapshotComposer")
struct AnnotationSnapshotComposerTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(
        id: String = "anno-1",
        kind: BibleAnnotationKind = .text,
        title: String,
        body: String
    ) -> BibleAnnotationRecord {
        BibleAnnotationRecord(
            id: id,
            target: .verse,
            bookId: "ROM",
            chapterNumber: 8,
            verseStart: 28,
            verseEnd: 30,
            kind: kind,
            title: title,
            body: body,
            source: .user,
            modelId: "test-model",
            createdAt: now
        )
    }

    @Test("single text card renders as H2 + blank line + body + trailing newline")
    func singleTextCard() {
        let snapshot = AnnotationSnapshotComposer.compose(
            annotation: record(title: "Author", body: "Paul, writing from Rome.")
        )
        #expect(snapshot == "## Author\n\nPaul, writing from Rome.\n")
    }

    @Test("single reference card renders the citation as the body")
    func singleReferenceCard() {
        let snapshot = AnnotationSnapshotComposer.compose(
            annotation: record(kind: .reference, title: "See also", body: "Heb 4:15")
        )
        #expect(snapshot == "## See also\n\nHeb 4:15\n")
    }

    @Test("multi-card snapshot separates cards with a blank line, preserves order")
    func multiCardSnapshot() {
        let cards = [
            record(id: "a", title: "Author", body: "Paul, writing from Rome."),
            record(id: "b", title: "Historical context", body: "Mixed Jew/Gentile church."),
            record(id: "c", kind: .reference, title: "See also", body: "Eph 1:11"),
        ]
        let snapshot = AnnotationSnapshotComposer.compose(annotations: cards)
        let expected = """
        ## Author

        Paul, writing from Rome.

        ## Historical context

        Mixed Jew/Gentile church.

        ## See also

        Eph 1:11

        """
        #expect(snapshot == expected)
    }

    @Test("empty input renders the empty string (no stray newlines)")
    func emptyInput() {
        #expect(AnnotationSnapshotComposer.compose(annotations: []) == "")
    }

    @Test("snapshot is line-deterministic for the same input")
    func deterministic() {
        let card = record(title: "Author", body: "Paul.")
        let first = AnnotationSnapshotComposer.compose(annotation: card)
        let second = AnnotationSnapshotComposer.compose(annotation: card)
        #expect(first == second)
    }
}
