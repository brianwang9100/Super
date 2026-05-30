import Foundation
import GRDB
import Testing
@testable import Chat

/// Tests for `ActiveConversationsRequest` — the Chats list's reactive
/// feed. Covers the `kind` filter added alongside the headless dispatch
/// pipeline so transient conversations never bleed into the sidebar.
@Suite("ActiveConversationsRequest")
struct ActiveConversationsRequestTests {
    @Test("user-kind conversations appear, transient-kind conversations are filtered out")
    func transientKindIsFilteredOut() async throws {
        let db = try ChatDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try await db.queue.write { db in
            try ConversationRecord(
                id: "user-1", title: "Visible", kind: .user,
                createdAt: now, updatedAt: now
            ).insert(db)
            try ConversationRecord(
                id: "transient-1", title: "Hidden", kind: .transient,
                createdAt: now, updatedAt: now
            ).insert(db)
        }

        let rows = try await db.queue.read { db in
            try ActiveConversationsRequest().fetch(db)
        }
        #expect(rows.map(\.id) == ["user-1"])
    }

    @Test("soft-deleted user conversations are still excluded")
    func softDeletedAreExcluded() async throws {
        let db = try ChatDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try await db.queue.write { db in
            try ConversationRecord(
                id: "live", title: "Live", kind: .user,
                createdAt: now, updatedAt: now
            ).insert(db)
            try ConversationRecord(
                id: "dead", title: "Dead", kind: .user,
                createdAt: now, updatedAt: now, deletedAt: now
            ).insert(db)
        }

        let rows = try await db.queue.read { db in
            try ActiveConversationsRequest().fetch(db)
        }
        #expect(rows.map(\.id) == ["live"])
    }

    @Test("rows are ordered newest-update-first")
    func orderedByUpdatedAtDescending() async throws {
        let db = try ChatDatabase.makeInMemory()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try await db.queue.write { db in
            try ConversationRecord(
                id: "old", title: "Old", kind: .user,
                createdAt: base, updatedAt: base
            ).insert(db)
            try ConversationRecord(
                id: "new", title: "New", kind: .user,
                createdAt: base, updatedAt: base.addingTimeInterval(60)
            ).insert(db)
        }

        let rows = try await db.queue.read { db in
            try ActiveConversationsRequest().fetch(db)
        }
        #expect(rows.map(\.id) == ["new", "old"])
    }
}
