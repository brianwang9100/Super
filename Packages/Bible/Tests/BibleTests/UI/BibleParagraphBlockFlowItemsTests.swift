import Testing
@testable import Bible

/// Tests for `BibleParagraphBlock.flowItems(_:annotationsByVerseEnd:notesByVerseEnd:)`
/// — the pure projection that interleaves verse words with their trailing
/// annotation bubbles and note glyphs inside `VerseFlowLayout`. Locks the
/// "word, then bubble(s), then note(s) per `isVerseEnd` token, then next word"
/// contract that snapshot tests can't surface in isolation.
@Suite("BibleParagraphBlock.flowItems")
@MainActor
struct BibleParagraphBlockFlowItemsTests {
    private static let spec1 = BibleAnnotationTargetSpec.verseRange(
        bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30
    )
    private static let spec2 = BibleAnnotationTargetSpec.verseRange(
        bookId: "ROM", chapterNumber: 8, verseStart: 29, verseEnd: 30
    )
    private static let note1 = BibleNoteTargetSpec.verseRange(
        bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30
    )
    private static let note2 = BibleNoteTargetSpec.verseRange(
        bookId: "ROM", chapterNumber: 8, verseStart: 30, verseEnd: 30
    )

    @Test("tokens with no annotations or notes produce a flat run of word items")
    func noTrailersEmitsOnlyWords() {
        let tokens = [
            token(verseNumber: 28, word: "For", isStart: true, isEnd: false),
            token(verseNumber: 28, word: "good.", isStart: false, isEnd: true),
        ]
        let items = BibleParagraphBlock.flowItems(
            tokens, annotationsByVerseEnd: [:], notesByVerseEnd: [:]
        )
        let expected: [BibleParagraphBlock.FlowItem] = tokens.map { .word($0) }
        #expect(items == expected)
    }

    @Test("a single bubble is emitted immediately after its verse-end word")
    func bubbleFollowsVerseEnd() {
        let tokens = [
            token(verseNumber: 30, word: "and", isStart: true, isEnd: false),
            token(verseNumber: 30, word: "glorified.", isStart: false, isEnd: true),
        ]
        let items = BibleParagraphBlock.flowItems(
            tokens,
            annotationsByVerseEnd: [30: [Self.spec1]],
            notesByVerseEnd: [:]
        )
        #expect(items.count == 3)
        if case .word(let last) = items[1] {
            #expect(last.word == "glorified.")
        } else {
            Issue.record("expected the second item to be the verse-end word")
        }
        #expect(items.last == .bubble(Self.spec1))
    }

    @Test("multiple bubbles for the same verseEnd stack in registration order")
    func stackedBubblesPreserveOrder() {
        let tokens = [
            token(verseNumber: 30, word: "glorified.", isStart: true, isEnd: true)
        ]
        let items = BibleParagraphBlock.flowItems(
            tokens,
            annotationsByVerseEnd: [30: [Self.spec1, Self.spec2]],
            notesByVerseEnd: [:]
        )
        // word + two bubbles, bubbles in argument order.
        #expect(items.count == 3)
        #expect(items[1] == .bubble(Self.spec1))
        #expect(items[2] == .bubble(Self.spec2))
    }

    @Test("a note glyph follows its verse-end word when there are no bubbles")
    func noteFollowsVerseEnd() {
        let tokens = [
            token(verseNumber: 30, word: "glorified.", isStart: true, isEnd: true)
        ]
        let items = BibleParagraphBlock.flowItems(
            tokens,
            annotationsByVerseEnd: [:],
            notesByVerseEnd: [30: [Self.note1]]
        )
        #expect(items.count == 2)
        #expect(items.last == .note(Self.note1))
    }

    @Test("notes are emitted after bubbles for the same verseEnd, locking the cluster order")
    func notesFollowBubbles() {
        let tokens = [
            token(verseNumber: 30, word: "glorified.", isStart: true, isEnd: true)
        ]
        let items = BibleParagraphBlock.flowItems(
            tokens,
            annotationsByVerseEnd: [30: [Self.spec1, Self.spec2]],
            notesByVerseEnd: [30: [Self.note1, Self.note2]]
        )
        // word + two bubbles + two notes, in [word, bubbles…, notes…] order.
        #expect(items.count == 5)
        #expect(items[1] == .bubble(Self.spec1))
        #expect(items[2] == .bubble(Self.spec2))
        #expect(items[3] == .note(Self.note1))
        #expect(items[4] == .note(Self.note2))
    }

    @Test("a token without isVerseEnd never emits a bubble or note even when the maps list its verse")
    func verseEndFlagGatesEmission() {
        // verse 28 has both an annotation and a note in the maps, but the only
        // token of verse 28 in this run isn't flagged as the end — emission
        // must wait for the final-fragment token in some later paragraph.
        let tokens = [
            token(verseNumber: 28, word: "Continuing", isStart: true, isEnd: false)
        ]
        let items = BibleParagraphBlock.flowItems(
            tokens,
            annotationsByVerseEnd: [28: [Self.spec1]],
            notesByVerseEnd: [28: [Self.note1]]
        )
        #expect(items.count == 1)
        if case .word = items[0] {} else {
            Issue.record("non-end token must emit only its word")
        }
    }

    private func token(
        verseNumber: Int,
        word: String,
        isStart: Bool,
        isEnd: Bool
    ) -> VerseWordToken {
        VerseWordToken(
            verseNumber: verseNumber,
            isVerseStart: isStart,
            isVerseEnd: isEnd,
            showsVerseNumber: isStart,
            word: word,
            verseText: word
        )
    }
}
