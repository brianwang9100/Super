import Testing
@testable import Bible

/// Tests for `BibleAnnotationTargetSpec` — the cross-cutting annotation
/// target identifier. The `id` projection is the load-bearing surface
/// (`.sheet(item:)` uses it), so the suite locks in identity stability
/// across cases.
@Suite("BibleAnnotationTargetSpec")
struct BibleAnnotationTargetSpecTests {
    @Test("id is stable for the book case")
    func bookId() {
        let spec = BibleAnnotationTargetSpec.book(bookId: "ROM")
        #expect(spec.id == "book:ROM")
        #expect(spec.target == .book)
        #expect(spec.bookId == "ROM")
        #expect(spec.chapterNumber == nil)
        #expect(spec.verseStart == nil)
        #expect(spec.verseEnd == nil)
    }

    @Test("id encodes chapter case discriminator")
    func chapterId() {
        let spec = BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)
        #expect(spec.id == "chapter:ROM:8")
        #expect(spec.target == .chapter)
        #expect(spec.chapterNumber == 8)
    }

    @Test("id encodes verse range start and end")
    func verseRangeId() {
        let spec = BibleAnnotationTargetSpec.verseRange(
            bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30
        )
        #expect(spec.id == "verse:ROM:8:28:30")
        #expect(spec.target == .verse)
        #expect(spec.verseStart == 28)
        #expect(spec.verseEnd == 30)
    }

    @Test("adjacent verse ranges in the same chapter have distinct ids")
    func adjacentVerseRangesDistinct() {
        let a = BibleAnnotationTargetSpec.verseRange(
            bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30
        )
        let b = BibleAnnotationTargetSpec.verseRange(
            bookId: "ROM", chapterNumber: 8, verseStart: 31, verseEnd: 32
        )
        #expect(a.id != b.id)
        #expect(a != b)
    }

    @Test("specs with the same case + values are Equatable-equal")
    func sameValuesEquatable() {
        let a = BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)
        let b = BibleAnnotationTargetSpec.chapter(bookId: "ROM", chapterNumber: 8)
        #expect(a == b)
        #expect(a.id == b.id)
    }
}
