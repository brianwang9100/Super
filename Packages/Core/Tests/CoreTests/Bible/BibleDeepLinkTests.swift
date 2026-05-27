import Foundation
import Testing
@testable import Core

/// Tests for `BibleDeepLink`'s three-way encoding between native fields,
/// URLs, and `RecordReference`s. Round-trips matter because the in-app
/// tap path (URL → reference) and the Bible-side receiver
/// (reference → coordinates) both depend on the same grammar.
@Suite("BibleDeepLink")
struct BibleDeepLinkTests {
    // MARK: - URL encoding

    @Test func urlForVerseRange() {
        let link = BibleDeepLink(bookId: "GEN", chapter: 1, verseStart: 1, verseEnd: 10)
        #expect(link.url.absoluteString == "super://bible/verse?book=GEN&chapter=1&verses=1-10")
    }

    @Test func urlForSingleVerse() {
        let link = BibleDeepLink(bookId: "JHN", chapter: 3, verseStart: 16)
        #expect(link.url.absoluteString == "super://bible/verse?book=JHN&chapter=3&verses=16")
    }

    @Test func urlForChapterOnly() {
        let link = BibleDeepLink(bookId: "PSA", chapter: 23)
        #expect(link.url.absoluteString == "super://bible/verse?book=PSA&chapter=23")
    }

    @Test func urlForSameStartAndEndCollapsesToSingleVerse() {
        // `verseStart == verseEnd` is equivalent to a single-verse ref;
        // we emit the shorter form so URLs are stable across constructors.
        let link = BibleDeepLink(bookId: "ROM", chapter: 8, verseStart: 28, verseEnd: 28)
        #expect(link.url.absoluteString == "super://bible/verse?book=ROM&chapter=8&verses=28")
    }

    // MARK: - URL parsing

    @Test func parseValidVerseRangeURL() throws {
        let url = try #require(URL(string: "super://bible/verse?book=ROM&chapter=8&verses=28-30"))
        let link = try #require(BibleDeepLink(url: url))
        #expect(link.bookId == "ROM")
        #expect(link.chapter == 8)
        #expect(link.verseStart == 28)
        #expect(link.verseEnd == 30)
    }

    @Test func parseValidSingleVerseURL() throws {
        let url = try #require(URL(string: "super://bible/verse?book=JHN&chapter=3&verses=16"))
        let link = try #require(BibleDeepLink(url: url))
        #expect(link.verseStart == 16)
        #expect(link.verseEnd == nil)
    }

    @Test func parseValidChapterOnlyURL() throws {
        let url = try #require(URL(string: "super://bible/verse?book=PSA&chapter=23"))
        let link = try #require(BibleDeepLink(url: url))
        #expect(link.verseStart == nil)
        #expect(link.verseEnd == nil)
    }

    @Test func rejectsWrongScheme() {
        let url = URL(string: "https://bible/verse?book=GEN&chapter=1")!
        #expect(BibleDeepLink(url: url) == nil)
    }

    @Test func rejectsWrongHost() {
        let url = URL(string: "super://todo/verse?book=GEN&chapter=1")!
        #expect(BibleDeepLink(url: url) == nil)
    }

    @Test func rejectsWrongPath() {
        let url = URL(string: "super://bible/chapter?book=GEN&chapter=1")!
        #expect(BibleDeepLink(url: url) == nil)
    }

    @Test func rejectsUnknownBookId() {
        let url = URL(string: "super://bible/verse?book=XXX&chapter=1")!
        #expect(BibleDeepLink(url: url) == nil)
    }

    @Test func rejectsOutOfRangeChapter() {
        // Genesis has 50 chapters.
        let url = URL(string: "super://bible/verse?book=GEN&chapter=51")!
        #expect(BibleDeepLink(url: url) == nil)
    }

    @Test func rejectsZeroChapter() {
        let url = URL(string: "super://bible/verse?book=GEN&chapter=0")!
        #expect(BibleDeepLink(url: url) == nil)
    }

    @Test func rejectsMissingChapter() {
        let url = URL(string: "super://bible/verse?book=GEN")!
        #expect(BibleDeepLink(url: url) == nil)
    }

    @Test func rejectsMissingBook() {
        let url = URL(string: "super://bible/verse?chapter=1")!
        #expect(BibleDeepLink(url: url) == nil)
    }

    @Test func rejectsNonIntegerChapter() {
        let url = URL(string: "super://bible/verse?book=GEN&chapter=one")!
        #expect(BibleDeepLink(url: url) == nil)
    }

    @Test func rejectsInvertedVerseRange() {
        let url = URL(string: "super://bible/verse?book=GEN&chapter=1&verses=10-5")!
        #expect(BibleDeepLink(url: url) == nil)
    }

    @Test func rejectsZeroVerse() {
        let url = URL(string: "super://bible/verse?book=GEN&chapter=1&verses=0")!
        #expect(BibleDeepLink(url: url) == nil)
    }

    @Test func rejectsMalformedVerses() {
        let url = URL(string: "super://bible/verse?book=GEN&chapter=1&verses=foo")!
        #expect(BibleDeepLink(url: url) == nil)
    }

    @Test func urlRoundTrip() throws {
        let original = BibleDeepLink(bookId: "1CO", chapter: 13, verseStart: 4, verseEnd: 7)
        let parsed = try #require(BibleDeepLink(url: original.url))
        #expect(parsed == original)
    }

    @Test func urlRoundTripChapterOnly() throws {
        let original = BibleDeepLink(bookId: "PSA", chapter: 23)
        let parsed = try #require(BibleDeepLink(url: original.url))
        #expect(parsed == original)
    }

    // MARK: - RecordReference encoding

    @Test func recordReferenceForVerseRange() {
        let link = BibleDeepLink(bookId: "GEN", chapter: 1, verseStart: 1, verseEnd: 10)
        let reference = link.recordReference
        #expect(reference.appletID == "bible")
        #expect(reference.kind == "verseRange")
        #expect(reference.sourceID == "GEN/1/1-10")
        #expect(reference.displayLabel == "Genesis 1:1-10")
        #expect(reference.citation == "Genesis 1:1-10")
        #expect(reference.snapshot == "")
    }

    @Test func recordReferenceForSingleVerse() {
        let link = BibleDeepLink(bookId: "JHN", chapter: 3, verseStart: 16)
        let reference = link.recordReference
        #expect(reference.sourceID == "JHN/3/16")
        #expect(reference.displayLabel == "John 3:16")
    }

    @Test func recordReferenceForChapterOnly() {
        let link = BibleDeepLink(bookId: "PSA", chapter: 23)
        let reference = link.recordReference
        #expect(reference.sourceID == "PSA/23")
        #expect(reference.displayLabel == "Psalms 23")
    }

    // MARK: - RecordReference parsing

    @Test func parseValidRecordReference() throws {
        let reference = RecordReference(
            appletID: "bible", kind: "verseRange", sourceID: "ROM/8/28-30",
            displayLabel: "Romans 8:28-30", citation: "Romans 8:28-30", snapshot: ""
        )
        let link = try #require(BibleDeepLink(reference: reference))
        #expect(link.bookId == "ROM")
        #expect(link.chapter == 8)
        #expect(link.verseStart == 28)
        #expect(link.verseEnd == 30)
    }

    @Test func parseChapterOnlyRecordReference() throws {
        let reference = RecordReference(
            appletID: "bible", kind: "verseRange", sourceID: "PSA/23",
            displayLabel: "Psalms 23", citation: "Psalms 23", snapshot: ""
        )
        let link = try #require(BibleDeepLink(reference: reference))
        #expect(link.verseStart == nil)
        #expect(link.verseEnd == nil)
    }

    @Test func rejectsRecordReferenceFromOtherApplet() {
        let reference = RecordReference(
            appletID: "todo", kind: "verseRange", sourceID: "GEN/1",
            displayLabel: "x", citation: "x", snapshot: ""
        )
        #expect(BibleDeepLink(reference: reference) == nil)
    }

    @Test func rejectsRecordReferenceFromWrongKind() {
        let reference = RecordReference(
            appletID: "bible", kind: "highlight", sourceID: "GEN/1",
            displayLabel: "x", citation: "x", snapshot: ""
        )
        #expect(BibleDeepLink(reference: reference) == nil)
    }

    @Test func rejectsMalformedSourceID() {
        let reference = RecordReference(
            appletID: "bible", kind: "verseRange", sourceID: "GEN",
            displayLabel: "x", citation: "x", snapshot: ""
        )
        #expect(BibleDeepLink(reference: reference) == nil)
    }

    @Test func recordReferenceRoundTrip() throws {
        let original = BibleDeepLink(bookId: "1JN", chapter: 4, verseStart: 7, verseEnd: 8)
        let parsed = try #require(BibleDeepLink(reference: original.recordReference))
        #expect(parsed == original)
    }
}
