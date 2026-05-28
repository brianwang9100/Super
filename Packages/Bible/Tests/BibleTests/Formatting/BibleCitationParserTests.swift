import Testing
@testable import Bible

/// Tests for `BibleCitationParser` — the citation-string-to-position
/// resolver used by `.reference`-kind annotation cards.
@Suite("BibleCitationParser")
struct BibleCitationParserTests {
    private let catalog = BibleBookCatalog.standard

    // MARK: - Standard forms

    @Test("single verse with full book name resolves")
    func singleVerseFullName() {
        let parsed = BibleCitationParser.parse("John 3:16", in: catalog)
        #expect(parsed?.position == BiblePosition(bookId: "JHN", chapterNumber: 3))
        #expect(parsed?.verseStart == 16)
        #expect(parsed?.verseEnd == 16)
    }

    @Test("verse range with full book name resolves")
    func verseRangeFullName() {
        let parsed = BibleCitationParser.parse("John 3:16-17", in: catalog)
        #expect(parsed?.position == BiblePosition(bookId: "JHN", chapterNumber: 3))
        #expect(parsed?.verseStart == 16)
        #expect(parsed?.verseEnd == 17)
    }

    @Test("multi-word book name with range resolves")
    func multiWordBookRange() {
        let parsed = BibleCitationParser.parse("1 Corinthians 13:4-7", in: catalog)
        #expect(parsed?.position == BiblePosition(bookId: "1CO", chapterNumber: 13))
        #expect(parsed?.verseStart == 4)
        #expect(parsed?.verseEnd == 7)
    }

    @Test("three-letter book abbreviation resolves")
    func threeLetterAbbreviation() {
        let parsed = BibleCitationParser.parse("Heb 4:15", in: catalog)
        #expect(parsed?.position == BiblePosition(bookId: "HEB", chapterNumber: 4))
        #expect(parsed?.verseStart == 15)
    }

    // MARK: - Case and spacing tolerance

    @Test("case-insensitive book matching")
    func caseInsensitive() {
        #expect(BibleCitationParser.parse("john 3:16", in: catalog)?.position.bookId == "JHN")
        #expect(BibleCitationParser.parse("JOHN 3:16", in: catalog)?.position.bookId == "JHN")
        #expect(BibleCitationParser.parse("1 cor 13:4", in: catalog)?.position.bookId == "1CO")
    }

    @Test("whitespace-stripped abbreviations resolve (1Cor → 1 Corinthians)")
    func gluedNumericPrefix() {
        let parsed = BibleCitationParser.parse("1Cor 13:4", in: catalog)
        #expect(parsed?.position == BiblePosition(bookId: "1CO", chapterNumber: 13))
        #expect(parsed?.verseStart == 4)
    }

    @Test("extra interior whitespace doesn't break parsing")
    func extraWhitespace() {
        let parsed = BibleCitationParser.parse("  Romans   8 : 28-30  ", in: catalog)
        #expect(parsed?.position == BiblePosition(bookId: "ROM", chapterNumber: 8))
        #expect(parsed?.verseStart == 28)
        #expect(parsed?.verseEnd == 30)
    }

    @Test("glued book and chapter (John3:16) resolves via digit boundary")
    func gluedBookAndChapter() {
        let parsed = BibleCitationParser.parse("John3:16", in: catalog)
        #expect(parsed?.position == BiblePosition(bookId: "JHN", chapterNumber: 3))
        #expect(parsed?.verseStart == 16)
    }

    // MARK: - Negative cases

    @Test("missing colon rejects")
    func missingColon() {
        #expect(BibleCitationParser.parse("John 3 16", in: catalog) == nil)
    }

    @Test("missing verse part rejects")
    func missingVerse() {
        #expect(BibleCitationParser.parse("John 3:", in: catalog) == nil)
    }

    @Test("non-numeric verse rejects")
    func nonNumericVerse() {
        #expect(BibleCitationParser.parse("John 3:abc", in: catalog) == nil)
    }

    @Test("inverted range rejects (verseEnd < verseStart)")
    func invertedRange() {
        #expect(BibleCitationParser.parse("John 3:17-16", in: catalog) == nil)
    }

    @Test("triple-segment verse rejects")
    func tripleSegmentVerse() {
        #expect(BibleCitationParser.parse("John 3:1-2-3", in: catalog) == nil)
    }

    @Test("unknown book name rejects")
    func unknownBook() {
        #expect(BibleCitationParser.parse("Hesiod 1:1", in: catalog) == nil)
    }

    @Test("ambiguous prefix rejects")
    func ambiguousPrefix() {
        // "J" prefix matches John, Jude, James, Jonah, Joel, Job, Joshua,
        // Judges, Jeremiah — eight or more. Reject.
        #expect(BibleCitationParser.parse("J 3:16", in: catalog) == nil)
    }

    @Test("chapter exceeding book chapter count rejects")
    func chapterOutOfRange() {
        // Jude has 1 chapter.
        #expect(BibleCitationParser.parse("Jude 2:1", in: catalog) == nil)
    }

    @Test("zero or negative verse rejects")
    func nonPositiveVerse() {
        #expect(BibleCitationParser.parse("John 3:0", in: catalog) == nil)
        #expect(BibleCitationParser.parse("John 3:-1", in: catalog) == nil)
    }

    @Test("empty string rejects")
    func emptyString() {
        #expect(BibleCitationParser.parse("", in: catalog) == nil)
        #expect(BibleCitationParser.parse("   ", in: catalog) == nil)
    }

    @Test("colon without book rejects")
    func colonWithoutBook() {
        #expect(BibleCitationParser.parse("3:16", in: catalog) == nil)
        #expect(BibleCitationParser.parse(":16", in: catalog) == nil)
    }

    // MARK: - Round-trip with formatter

    @Test("parser round-trips clean citations produced by the formatter")
    func roundTripWithFormatter() {
        let formatted = BibleCitationFormatter.cite(
            bookName: "Romans", chapterNumber: 8, verses: [28, 29, 30]
        )
        #expect(formatted == "Romans 8:28-30")
        let parsed = BibleCitationParser.parse(formatted, in: catalog)
        #expect(parsed?.position == BiblePosition(bookId: "ROM", chapterNumber: 8))
        #expect(parsed?.verseStart == 28)
        #expect(parsed?.verseEnd == 30)
    }
}
