import Core
import Foundation
import GRDB
import Testing
@testable import Chat

/// Tests for `GRDBCompactionCheckpointRepository` — single-live-per-
/// conversation invariant, transaction rollback, and scoped reads/deletes.
@Suite("GRDBCompactionCheckpointRepository")
struct CompactionCheckpointRepositoryTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Setup {
        let database: ChatDatabase
        let checkpoints: GRDBCompactionCheckpointRepository
        let conversations: GRDBConversationRepository
    }

    private func makeSetup() async throws -> Setup {
        let db = try ChatDatabase.makeInMemory()
        let setup = Setup(
            database: db,
            checkpoints: GRDBCompactionCheckpointRepository(database: db),
            conversations: GRDBConversationRepository(database: db)
        )
        try await setup.conversations.save(ConversationRecord(
            id: "c1", title: "T", createdAt: now, updatedAt: now
        ))
        try await setup.conversations.save(ConversationRecord(
            id: "c2", title: "Other", createdAt: now, updatedAt: now
        ))
        return setup
    }

    private func makeCheckpoint(
        id: String,
        conversationId: String = "c1",
        upto: String = "m1",
        offset: TimeInterval = 0,
        live: Bool = true
    ) -> CompactionCheckpointRecord {
        CompactionCheckpointRecord(
            id: id,
            conversationId: conversationId,
            uptoMessageId: upto,
            summary: "summary-\(id)",
            tokensBefore: 4_000,
            tokensAfter: 800,
            createdAt: now.addingTimeInterval(offset),
            isLive: live
        )
    }

    @Test func savingNewLiveCheckpointSupersedesPriorLiveOne() async throws {
        let s = try await makeSetup()
        try await s.checkpoints.save(makeCheckpoint(id: "cp1", offset: 0))
        try await s.checkpoints.save(makeCheckpoint(id: "cp2", offset: 60))

        let live = try await s.checkpoints.liveCheckpoint(for: "c1")
        #expect(live?.id == "cp2")

        let history = try await s.checkpoints.all(for: "c1")
        #expect(history.map(\.id) == ["cp2", "cp1"])
        #expect(history.filter(\.isLive).count == 1)
    }

    @Test func savingNonLiveCheckpointDoesNotTouchPriorLive() async throws {
        let s = try await makeSetup()
        try await s.checkpoints.save(makeCheckpoint(id: "cp1", offset: 0))
        try await s.checkpoints.save(makeCheckpoint(id: "cp_audit", offset: 30, live: false))

        let live = try await s.checkpoints.liveCheckpoint(for: "c1")
        #expect(live?.id == "cp1")
    }

    @Test func failedReplacementRollsBackPriorLiveCheckpointDemotion() async throws {
        let s = try await makeSetup()
        let prior = makeCheckpoint(id: "cp-old")
        let sibling = makeCheckpoint(id: "cp-sibling", conversationId: "c2", offset: 15)
        try await s.checkpoints.save(prior)
        try await s.checkpoints.save(sibling)
        try await s.database.queue.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER reject_checkpoint_replacement
                BEFORE INSERT ON compactionCheckpoint
                WHEN NEW.id = 'cp-new'
                BEGIN
                    SELECT RAISE(ABORT, 'checkpoint replacement rejected');
                END
                """)
        }

        await #expect(throws: DatabaseError.self) {
            try await s.checkpoints.save(makeCheckpoint(id: "cp-new", offset: 30))
        }

        #expect(try await s.checkpoints.all(for: "c1") == [prior])
        #expect(try await s.checkpoints.liveCheckpoint(for: "c1") == prior)
        #expect(try await s.checkpoints.all(for: "c2") == [sibling])
    }

    @Test func deleteRemovesOnlyRequestedCheckpointsAndEmptyIDsPreserveSurvivors() async throws {
        let s = try await makeSetup()
        let prior = makeCheckpoint(id: "cp-prior", live: false)
        let live = makeCheckpoint(id: "cp-live", offset: 30)
        let sibling = makeCheckpoint(id: "cp-sibling", conversationId: "c2", offset: 15)
        try await s.checkpoints.save(prior)
        try await s.checkpoints.save(live)
        try await s.checkpoints.save(sibling)

        try await s.checkpoints.delete(ids: ["cp-live", "missing"])
        #expect(try await s.checkpoints.all(for: "c1") == [prior])
        #expect(try await s.checkpoints.liveCheckpoint(for: "c1") == nil)
        #expect(try await s.checkpoints.all(for: "c2") == [sibling])

        try await s.checkpoints.delete(ids: [])
        #expect(try await s.checkpoints.all(for: "c1") == [prior])
        #expect(try await s.checkpoints.all(for: "c2") == [sibling])
    }

    @Test func liveCheckpointIsScopedByConversation() async throws {
        let s = try await makeSetup()
        try await s.checkpoints.save(makeCheckpoint(id: "cp_c1", conversationId: "c1"))
        try await s.checkpoints.save(makeCheckpoint(id: "cp_c2", conversationId: "c2"))

        // Saving a new live row in c1 must not demote the live row in c2.
        try await s.checkpoints.save(makeCheckpoint(id: "cp_c1_new", conversationId: "c1", offset: 60))

        #expect(try await s.checkpoints.liveCheckpoint(for: "c1")?.id == "cp_c1_new")
        #expect(try await s.checkpoints.liveCheckpoint(for: "c2")?.id == "cp_c2")
    }

    @Test func liveCheckpointReturnsNilWhenNoneExist() async throws {
        let s = try await makeSetup()
        #expect(try await s.checkpoints.liveCheckpoint(for: "c1") == nil)
    }

    @Test func resavingSameLiveRowKeepsItLive() async throws {
        let s = try await makeSetup()
        let cp = makeCheckpoint(id: "cp1")
        try await s.checkpoints.save(cp)
        try await s.checkpoints.save(cp)
        let history = try await s.checkpoints.all(for: "c1")
        #expect(history.count == 1)
        #expect(history.first?.isLive == true)
    }
}
