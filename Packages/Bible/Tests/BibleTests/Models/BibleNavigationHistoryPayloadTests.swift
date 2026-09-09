import Foundation
import Testing
@testable import Bible

/// Tests for versioned Bible history encoding and corruption recovery.
@Suite("BibleNavigationHistoryPayload")
struct BibleNavigationHistoryPayloadTests {
    private let fallback = BiblePosition(bookId: "1PE", chapterNumber: 2)
    private let catalog = BibleBookCatalog.standard

    @Test("version 1 payload round-trips entries and cursor")
    func roundTrip() throws {
        let a = BiblePosition(bookId: "1PE", chapterNumber: 2)
        let b = BiblePosition(bookId: "JHN", chapterNumber: 3)
        let c = BiblePosition(bookId: "PSA", chapterNumber: 23)
        var history = BibleNavigationHistory(initialPosition: a)
        let visitedB = history.visit(b)
        let visitedC = history.visit(c)
        let wentBack = history.goBack()
        #expect(visitedB)
        #expect(visitedC)
        #expect(wentBack)

        let json = try BibleNavigationHistoryPayload.encode(history)
        let restored = BibleNavigationHistoryPayload.restore(
            from: json,
            position: b,
            catalog: catalog
        )

        #expect(restored == history)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        #expect(object["version"] as? Int == 1)
    }

    @Test("missing and malformed payloads recover to the saved position", arguments: [nil, "", "not-json"])
    func missingOrMalformedPayload(json: String?) {
        expectFallback(for: json)
    }

    @Test("unsupported payload versions recover to the saved position")
    func unsupportedVersion() {
        expectFallback(for: payload(version: 2, entries: [fallback], currentIndex: 0))
    }

    @Test("empty and oversized histories recover to the saved position")
    func invalidEntryCounts() {
        expectFallback(for: payload(version: 1, entries: [], currentIndex: 0))
        let entries = (1...26).map { BiblePosition(bookId: "PSA", chapterNumber: $0) }
        expectFallback(for: payload(version: 1, entries: entries, currentIndex: 25))
    }

    @Test("unknown books and invalid chapters recover to the saved position")
    func invalidCatalogDestinations() {
        expectFallback(for: payload(
            version: 1,
            entries: [BiblePosition(bookId: "NOPE", chapterNumber: 1)],
            currentIndex: 0
        ))
        expectFallback(for: payload(
            version: 1,
            entries: [BiblePosition(bookId: "JHN", chapterNumber: 22)],
            currentIndex: 0
        ))
        expectFallback(for: payload(
            version: 1,
            entries: [BiblePosition(bookId: "JHN", chapterNumber: 0)],
            currentIndex: 0
        ))
    }

    @Test("out-of-bounds cursors recover to the saved position")
    func invalidCursor() {
        expectFallback(for: payload(version: 1, entries: [fallback], currentIndex: -1))
        expectFallback(for: payload(version: 1, entries: [fallback], currentIndex: 1))
    }

    @Test("a cursor that disagrees with the saved row recovers to the saved position")
    func cursorRowDisagreement() {
        expectFallback(for: payload(
            version: 1,
            entries: [fallback, BiblePosition(bookId: "JHN", chapterNumber: 3)],
            currentIndex: 1
        ))
    }

    private func expectFallback(for json: String?) {
        let restored = BibleNavigationHistoryPayload.restore(
            from: json,
            position: fallback,
            catalog: catalog
        )
        #expect(restored.entries == [fallback])
        #expect(restored.current == fallback)
        #expect(!restored.canGoBack)
        #expect(!restored.canGoForward)
    }

    private func payload(
        version: Int,
        entries: [BiblePosition],
        currentIndex: Int
    ) -> String {
        let rawEntries: [[String: Any]] = entries.map {
            ["bookId": $0.bookId, "chapterNumber": $0.chapterNumber]
        }
        let data = try! JSONSerialization.data(withJSONObject: [
            "version": version,
            "entries": rawEntries,
            "currentIndex": currentIndex,
        ], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
