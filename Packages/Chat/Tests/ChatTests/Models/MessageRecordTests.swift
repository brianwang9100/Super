import Core
import Foundation
import Testing
@testable import Chat

/// Tests for `MessageRecord`'s structured-attachment accessors — the
/// `attachments` decode and the `encode(_:)` writer that backs the
/// `attachmentsJSON` column.
@Suite("MessageRecord attachments")
struct MessageRecordTests {
    private func reference() -> RecordReference {
        RecordReference(
            appletID: "bible", kind: "verseRange", sourceID: "WEB/JHN/3/16",
            displayLabel: "John 3:16 (WEB)", citation: "John 3:16 (WEB)",
            snapshot: "For God so loved the world...", id: "r1"
        )
    }

    private func message(attachmentsJSON: String?) -> MessageRecord {
        MessageRecord(
            id: "m1", conversationId: "c1", role: .user, content: "hi",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            attachmentsJSON: attachmentsJSON
        )
    }

    @Test func attachmentsIsNilWhenColumnIsNil() {
        let record = message(attachmentsJSON: nil)
        #expect(record.attachmentsJSON == nil)
        #expect(record.attachments == nil)
    }

    @Test func encodeThenDecodeRoundTripsReferences() {
        let attachments = MessageAttachments(references: [reference()])
        let json = MessageRecord.encode(attachments)
        #expect(json != nil)
        #expect(message(attachmentsJSON: json).attachments == attachments)
    }

    @Test func encodeReturnsNilForEmptyAttachments() {
        #expect(MessageRecord.encode(MessageAttachments(references: [])) == nil)
    }

    @Test func attachmentsIsNilForMalformedJSON() {
        #expect(message(attachmentsJSON: "{not json").attachments == nil)
    }
}
