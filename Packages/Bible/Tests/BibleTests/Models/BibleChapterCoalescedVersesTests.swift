import Testing
@testable import Bible

/// Tests for `BibleChapter.coalescedVerses()` — the fragment-joining that turns
/// a chapter's paragraphs into one entry per verse number.
@Suite("BibleChapter.coalescedVerses")
struct BibleChapterCoalescedVersesTests {
    @Test("fragments of the same verse across paragraphs join into one entry")
    func coalescesFragments() {
        let chapter = BibleChapter(number: 1, paragraphs: [
            .poetry([BibleVerse(number: 1, text: "Line one")]),
            .poetry([BibleVerse(number: 1, text: "line two")]),
            .heading("A heading"),
            .prose([BibleVerse(number: 2, text: "Second verse.")]),
        ])
        let verses = chapter.coalescedVerses()
        #expect(verses.map(\.number) == [1, 2])
        #expect(verses[0].text == "Line one line two")
        #expect(verses[1].text == "Second verse.")
    }

    @Test("newlines within a fragment flatten to spaces")
    func flattensNewlines() {
        let chapter = BibleChapter(number: 1, paragraphs: [
            .poetry([BibleVerse(number: 1, text: "a\nb")]),
        ])
        #expect(chapter.coalescedVerses().first?.text == "a b")
    }

    @Test("headings contribute no verses")
    func headingsSkipped() {
        let chapter = BibleChapter(number: 1, paragraphs: [
            .heading("Title"),
            .prose([BibleVerse(number: 1, text: "Only verse.")]),
        ])
        #expect(chapter.coalescedVerses().map(\.number) == [1])
    }
}
