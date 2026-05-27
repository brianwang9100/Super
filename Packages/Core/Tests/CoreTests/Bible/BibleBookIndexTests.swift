import Testing
@testable import Core

/// Tests for `BibleBookIndex` — full canon coverage, alias resolution,
/// and the longest-spelling-first ordering that lets the parser match
/// multi-word books before their single-word substrings.
@Suite("BibleBookIndex")
struct BibleBookIndexTests {
    @Test func canonicalContainsAllSixtySixBooks() {
        #expect(BibleBookIndex.canonical.count == 66)
    }

    @Test func canonicalIdsAreUnique() {
        let ids = BibleBookIndex.canonical.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func canonicalNamesAreUnique() {
        let names = BibleBookIndex.canonical.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test func lookupByExactName() {
        #expect(BibleBookIndex.lookup("Genesis")?.id == "GEN")
        #expect(BibleBookIndex.lookup("Revelation")?.id == "REV")
        #expect(BibleBookIndex.lookup("1 Corinthians")?.id == "1CO")
        #expect(BibleBookIndex.lookup("Song of Solomon")?.id == "SNG")
    }

    @Test func lookupResolvesAliases() {
        #expect(BibleBookIndex.lookup("Psalm")?.id == "PSA")
        #expect(BibleBookIndex.lookup("Psalms")?.id == "PSA")
        #expect(BibleBookIndex.lookup("Song of Songs")?.id == "SNG")
    }

    @Test func lookupIsCaseSensitive() {
        // Lower-case rejection is deliberate — see the file-level doc on
        // why we don't fold case here.
        #expect(BibleBookIndex.lookup("genesis") == nil)
        #expect(BibleBookIndex.lookup("GENESIS") == nil)
    }

    @Test func lookupReturnsNilForUnknownName() {
        #expect(BibleBookIndex.lookup("Hezekiah") == nil)
        #expect(BibleBookIndex.lookup("Gen") == nil) // abbreviations not in v1
    }

    @Test func entryByIdReturnsCanonicalRow() {
        #expect(BibleBookIndex.entry(id: "GEN")?.name == "Genesis")
        #expect(BibleBookIndex.entry(id: "1JN")?.name == "1 John")
        #expect(BibleBookIndex.entry(id: "SNG")?.name == "Song of Solomon")
    }

    @Test func entryByUnknownIdIsNil() {
        #expect(BibleBookIndex.entry(id: "XXX") == nil)
        #expect(BibleBookIndex.entry(id: "") == nil)
    }

    @Test func spellingsAreOrderedLongestFirst() {
        // Crucial invariant: longer spellings appear before any of their
        // proper prefixes/substrings, so a left-to-right matcher never
        // matches "John" inside "1 John" before getting a chance to match
        // the full "1 John".
        let lengths = BibleBookIndex.spellingsLongestFirst.map { $0.spelling.count }
        let sortedDesc = lengths.sorted(by: >)
        #expect(lengths == sortedDesc)
    }

    @Test func longerSpellingsPrecedeTheirPrefixes() {
        let spellings = BibleBookIndex.spellingsLongestFirst.map(\.spelling)
        // "1 John" must appear before plain "John" so a left-to-right match
        // resolves "1 John 3:16" to 1JN, not JHN.
        let johnIndex = spellings.firstIndex(of: "John")
        let firstJohnIndex = spellings.firstIndex(of: "1 John")
        #expect(firstJohnIndex != nil && johnIndex != nil && firstJohnIndex! < johnIndex!)
        // Same constraint for "Song of Solomon"/"Song of Songs" vs any
        // shorter "Song" prefix — none exists today, but the ordering
        // invariant proven above means future shorter aliases stay safe.
    }

    @Test func psalmsChapterCountMatchesCanon() {
        #expect(BibleBookIndex.entry(id: "PSA")?.chapterCount == 150)
    }

    @Test func aliasesResolveToSameEntryAsCanonicalName() {
        #expect(BibleBookIndex.lookup("Psalm") == BibleBookIndex.lookup("Psalms"))
        #expect(BibleBookIndex.lookup("Song of Songs") == BibleBookIndex.lookup("Song of Solomon"))
    }
}
