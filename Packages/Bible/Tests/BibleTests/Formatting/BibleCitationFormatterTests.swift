import Testing
@testable import Bible

/// Tests for `BibleCitationFormatter` — the run compression that turns a set
/// of verse numbers into a citation clause, and the full citation it builds.
@Suite("BibleCitationFormatter")
struct BibleCitationFormatterTests {
    @Test("a single verse renders as itself")
    func singleVerse() {
        #expect(BibleCitationFormatter.verseClause([9]) == "9")
    }

    @Test("a contiguous run collapses to a range")
    func contiguousRun() {
        #expect(BibleCitationFormatter.verseClause([4, 5, 6]) == "4-6")
    }

    @Test("ranges and singletons join with commas")
    func mixedRunsAndSingletons() {
        #expect(BibleCitationFormatter.verseClause([4, 5, 6, 9]) == "4-6, 9")
        #expect(BibleCitationFormatter.verseClause([1, 3, 5]) == "1, 3, 5")
        #expect(BibleCitationFormatter.verseClause([1, 2, 5, 6]) == "1-2, 5-6")
    }

    @Test("out-of-order and duplicate numbers are sorted and deduplicated")
    func unsortedInputIsNormalized() {
        #expect(BibleCitationFormatter.verseClause([9, 4, 6, 5]) == "4-6, 9")
        #expect(BibleCitationFormatter.verseClause([9, 9, 4, 4]) == "4, 9")
    }

    @Test("an empty selection yields an empty clause")
    func emptyClause() {
        #expect(BibleCitationFormatter.verseClause([]) == "")
    }

    @Test("a full citation joins the book, chapter, and verse clause")
    func fullCitation() {
        #expect(
            BibleCitationFormatter.cite(bookName: "1 Peter", chapterNumber: 2, verses: [4, 5, 6, 9])
                == "1 Peter 2:4-6, 9"
        )
    }

    @Test("a citation with no verses names the whole chapter")
    func chapterOnlyCitation() {
        #expect(
            BibleCitationFormatter.cite(bookName: "Romans", chapterNumber: 8, verses: [])
                == "Romans 8"
        )
    }
}
