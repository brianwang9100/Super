import Testing
@testable import Bible

/// Tests for `BibleSearchQueryParser` — the progressive picker-search parser
/// that turns `"1 Peter"`, `"1 Peter 2"`, and `"1 Peter 2:5-6"` into a
/// book-list filter plus an optional chapter / verse deep-link target.
@Suite("BibleSearchQueryParser")
struct BibleSearchQueryParserTests {
    private let catalog = BibleBookCatalog.standard

    private func parse(_ raw: String) -> BibleSearchQuery {
        BibleSearchQueryParser.parse(raw, in: catalog)
    }

    @Test("an empty or whitespace query resolves to nothing and an empty filter")
    func emptyQuery() {
        #expect(parse("") == BibleSearchQuery(bookNameQuery: "", resolved: nil))
        #expect(parse("   ") == BibleSearchQuery(bookNameQuery: "", resolved: nil))
    }

    @Test("a plain book name is a book-only filter")
    func bookOnly() {
        let result = parse("1 Peter")
        #expect(result.bookNameQuery == "1 Peter")
        #expect(result.resolved == nil)
    }

    @Test("a partial book name keeps the whole query as the filter")
    func partialBookName() {
        let result = parse("Peter")
        #expect(result.bookNameQuery == "Peter")
        #expect(result.resolved == nil)
    }

    @Test("a numeric-prefix book plus chapter resolves to that chapter")
    func numericPrefixBookChapter() {
        let result = parse("1 Peter 2")
        #expect(result.resolved == .chapter(bookId: "1PE", bookName: "1 Peter", chapterNumber: 2))
    }

    @Test("a single-word book plus chapter resolves to that chapter")
    func singleWordBookChapter() {
        #expect(parse("Genesis 3").resolved == .chapter(bookId: "GEN", bookName: "Genesis", chapterNumber: 3))
        #expect(parse("Psalms 119").resolved == .chapter(bookId: "PSA", bookName: "Psalms", chapterNumber: 119))
    }

    @Test("book chapter:verse resolves to a single-verse range")
    func singleVerse() {
        #expect(
            parse("John 3:16").resolved
                == .verseRange(bookId: "JHN", bookName: "John", chapterNumber: 3, verseStart: 16, verseEnd: 16)
        )
    }

    @Test("book chapter:start-end resolves to a verse range")
    func verseRange() {
        #expect(
            parse("1 Peter 2:5-6").resolved
                == .verseRange(bookId: "1PE", bookName: "1 Peter", chapterNumber: 2, verseStart: 5, verseEnd: 6)
        )
    }

    @Test("a trailing colon with no verse yet stays a chapter result")
    func trailingColon() {
        #expect(parse("1 Peter 2:").resolved == .chapter(bookId: "1PE", bookName: "1 Peter", chapterNumber: 2))
    }

    @Test("a half-typed range collapses to its start verse")
    func halfTypedRange() {
        #expect(
            parse("1 Peter 2:5-").resolved
                == .verseRange(bookId: "1PE", bookName: "1 Peter", chapterNumber: 2, verseStart: 5, verseEnd: 5)
        )
    }

    @Test("an inverted range falls back to a chapter result")
    func invertedRange() {
        // 6 < 5 is rejected by the verse parser, so the row still offers the chapter.
        #expect(parse("1 Peter 2:6-5").resolved == .chapter(bookId: "1PE", bookName: "1 Peter", chapterNumber: 2))
    }

    @Test("an ambiguous book with a chapter falls back to book filtering")
    func ambiguousBookWithChapter() {
        let result = parse("Peter 2")
        #expect(result.resolved == nil)
        #expect(result.bookNameQuery == "Peter")   // lists 1 Peter + 2 Peter
    }

    @Test("an out-of-range chapter falls back to book filtering")
    func outOfRangeChapter() {
        let result = parse("1 Peter 9")            // 1 Peter has 5 chapters
        #expect(result.resolved == nil)
        #expect(result.bookNameQuery == "1 Peter")
    }

    @Test("a lone leading digit stays a book filter, not a chapter")
    func loneDigitIsBookFilter() {
        let result = parse("1")
        #expect(result.resolved == nil)
        #expect(result.bookNameQuery == "1")       // 1 Samuel, 1 Kings, 1 Peter, …
    }

    @Test("a multi-word numeric-prefix book without a chapter stays book-only")
    func multiWordNumericPrefixBookOnly() {
        let result = parse("2 John")
        #expect(result.resolved == nil)
        #expect(result.bookNameQuery == "2 John")
    }

    @Test("surrounding whitespace is trimmed")
    func trimsWhitespace() {
        #expect(parse("  1 Peter 2  ").resolved == .chapter(bookId: "1PE", bookName: "1 Peter", chapterNumber: 2))
    }

    @Test("a unique prefix plus chapter resolves")
    func prefixBookChapter() {
        #expect(parse("Gen 1").resolved == .chapter(bookId: "GEN", bookName: "Genesis", chapterNumber: 1))
    }

    @Test("display labels and subtitles read naturally")
    func labels() {
        let chapter = BibleSearchResult.chapter(bookId: "1PE", bookName: "1 Peter", chapterNumber: 2)
        #expect(chapter.displayLabel == "1 Peter 2")
        #expect(chapter.subtitle == "Go to chapter")

        let single = BibleSearchResult.verseRange(
            bookId: "1PE", bookName: "1 Peter", chapterNumber: 2, verseStart: 5, verseEnd: 5
        )
        #expect(single.displayLabel == "1 Peter 2:5")
        #expect(single.subtitle == "Go to verse")

        let range = BibleSearchResult.verseRange(
            bookId: "1PE", bookName: "1 Peter", chapterNumber: 2, verseStart: 5, verseEnd: 6
        )
        #expect(range.displayLabel == "1 Peter 2:5-6")
        #expect(range.subtitle == "Go to verses")
    }
}
