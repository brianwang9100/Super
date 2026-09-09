import Core
import Testing
@testable import Bible

@Suite("BibleReaderReference")
struct BibleReaderReferenceTests {
    @Test(arguments: [Set<Int>(), [28], [28, 29, 30], [28, 30]])
    func roundTrip(verses: Set<Int>) throws {
        let target = BibleReaderReference(
            position: BiblePosition(bookId: "ROM", chapterNumber: 8),
            translation: .bsb,
            selectedVerses: verses
        )
        let reference = target.recordReference
        #expect(reference.kind == "readerPosition")
        #expect(BibleDeepLink(reference: reference) == nil)
        #expect(try #require(BibleReaderReference(reference: reference)) == target)
    }

    @Test("encoding is canonical and retains disjoint verses")
    func canonicalEncoding() {
        let target = BibleReaderReference(
            position: BiblePosition(bookId: "ROM", chapterNumber: 8),
            translation: .web, selectedVerses: [30, 28]
        )
        #expect(target.recordReference.sourceID == "v1/WEB/ROM/8/28,30")
        #expect(target.recordReference.citation == "Romans 8:28, 30 (WEB)")
    }

    @Test(arguments: [
        "v2/WEB/ROM/8/28", "v1/UNKNOWN/ROM/8/28", "v1/WEB/ZZZ/8/28",
        "v1/WEB/ROM/0", "v1/WEB/ROM/17", "v1/WEB/ROM/eight", "v1/WEB/ROM/8/",
        "v1/WEB/ROM/8/0", "v1/WEB/ROM/8/-1", "v1/WEB/ROM/8/28-30",
        "v1/WEB/ROM/8/28,,30", "v1/WEB/ROM/8/28,28", "v1/WEB/ROM/8/30,28",
        "v1/WEB/ROM/8/28/30", "v1/WEB/ROM/8/+28", "v1/WEB/ROM/8/028",
    ])
    func rejectsMalformedSource(source: String) {
        #expect(BibleReaderReference(reference: reference(source)) == nil)
    }

    @Test("the codec never accepts attachment or other applet references")
    func rejectsOtherKinds() {
        #expect(BibleReaderReference(reference: reference("v1/WEB/ROM/8", kind: "verseRange")) == nil)
        #expect(BibleReaderReference(reference: reference("v1/WEB/ROM/8", applet: "todo")) == nil)
        #expect(BibleReaderReference(reference: reference("WEB/ROM/8/28,30", kind: "verseRange")) == nil)
    }

    private func reference(_ source: String, kind: String = "readerPosition", applet: String = "bible") -> RecordReference {
        RecordReference(appletID: applet, kind: kind, sourceID: source, displayLabel: "", citation: "", snapshot: "", id: "test")
    }
}
