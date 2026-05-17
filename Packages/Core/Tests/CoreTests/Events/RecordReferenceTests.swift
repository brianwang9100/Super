import Foundation
import Testing
@testable import Core

/// Tests for `RecordReference`'s value semantics and `Codable` round-trip —
/// the latter matters because the same type is persisted into a message's
/// attachment column, not just passed over the event bus.
@Suite("RecordReference")
struct RecordReferenceTests {
    private func sample(id: String = "ref-1") -> RecordReference {
        RecordReference(
            appletID: "bible",
            kind: "verseRange",
            sourceID: "WEB/JHN/3/16-17",
            displayLabel: "John 3:16-17 (WEB)",
            citation: "John 3:16-17 (WEB)",
            snapshot: "For God so loved the world...",
            id: id
        )
    }

    @Test func initStoresAllFields() {
        let reference = sample()
        #expect(reference.appletID == "bible")
        #expect(reference.kind == "verseRange")
        #expect(reference.sourceID == "WEB/JHN/3/16-17")
        #expect(reference.id == "ref-1")
        #expect(reference.displayLabel == "John 3:16-17 (WEB)")
        #expect(reference.citation == "John 3:16-17 (WEB)")
        #expect(reference.snapshot == "For God so loved the world...")
    }

    @Test func idDefaultsToAFreshUUIDPerInstance() {
        let first = RecordReference(
            appletID: "bible", kind: "verseRange", sourceID: "WEB/JHN/3/16",
            displayLabel: "John 3:16 (WEB)", citation: "John 3:16 (WEB)", snapshot: "x"
        )
        let second = RecordReference(
            appletID: "bible", kind: "verseRange", sourceID: "WEB/JHN/3/16",
            displayLabel: "John 3:16 (WEB)", citation: "John 3:16 (WEB)", snapshot: "x"
        )
        // Same verse added twice → distinct pill identities.
        #expect(first.id != second.id)
        #expect(first != second)
    }

    @Test func codableRoundTripPreservesEveryField() throws {
        let original = sample()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RecordReference.self, from: data)
        #expect(decoded == original)
    }

    @Test func equalInstancesCompareEqual() {
        #expect(sample(id: "same") == sample(id: "same"))
    }
}
