import Core
import Foundation
import GRDB
import Testing
@testable import Chat

/// Tests for the GRDB encoding and decoding of nullable message attachments.
/// The shared schema snapshot owns the attachments-column shape.
@Suite("MessageRecord attachments migration")
struct MessageAttachmentsMigrationTests {
    @Test func messageWithAttachmentsRoundTripsThroughGRDB() async throws {
        let db = try ChatDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reference = RecordReference(
            appletID: "bible", kind: "verseRange", sourceID: "WEB/JHN/3/16",
            displayLabel: "John 3:16 (WEB)", citation: "John 3:16 (WEB)",
            snapshot: "For God so loved the world...", id: "r1"
        )
        let json = MessageRecord.encode(MessageAttachments(references: [reference]))
        // `message.conversationId` is a cascading FK — insert the parent first.
        let conversation = ConversationRecord(id: "c1", createdAt: now, updatedAt: now)
        let message = MessageRecord(
            id: "m1", conversationId: "c1", role: .user, content: "Explain this",
            createdAt: now, attachmentsJSON: json
        )

        try await db.queue.write { db in
            try conversation.insert(db)
            try message.insert(db)
        }
        let fetched = try await db.queue.read { db in
            try MessageRecord.fetchOne(db, key: "m1")
        }

        #expect(fetched?.attachmentsJSON == json)
        #expect(fetched?.attachments?.references == [reference])
    }

    @Test func messageWithoutAttachmentsStoresNullColumn() async throws {
        let db = try ChatDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let conversation = ConversationRecord(id: "c1", createdAt: now, updatedAt: now)
        let message = MessageRecord(
            id: "m1", conversationId: "c1", role: .user, content: "plain", createdAt: now
        )

        try await db.queue.write { db in
            try conversation.insert(db)
            try message.insert(db)
        }
        let fetched = try await db.queue.read { db in
            try MessageRecord.fetchOne(db, key: "m1")
        }

        #expect(fetched?.attachmentsJSON == nil)
        #expect(fetched?.attachments == nil)
    }
}
