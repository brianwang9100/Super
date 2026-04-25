import Foundation
import Testing
@testable import Chat

/// Tests for `GRDBToolCallRepository` indexed lookups and status transitions.
@Suite("GRDBToolCallRepository")
struct ToolCallRepositoryTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Setup {
        let database: ChatDatabase
        let tools: GRDBToolCallRepository
        let messages: GRDBMessageRepository
        let conversations: GRDBConversationRepository
    }

    private func makeSetup() async throws -> Setup {
        let db = try ChatDatabase.makeInMemory()
        let setup = Setup(
            database: db,
            tools: GRDBToolCallRepository(database: db),
            messages: GRDBMessageRepository(database: db),
            conversations: GRDBConversationRepository(database: db)
        )
        try await setup.conversations.save(ConversationRecord(
            id: "c1", title: "T", createdAt: now, updatedAt: now
        ))
        try await setup.messages.save(MessageRecord(
            id: "m1", conversationId: "c1", role: .assistant, content: "calling", createdAt: now
        ))
        return setup
    }

    @Test func fetchByMessageReturnsOnlyThatMessagesCalls() async throws {
        let s = try await makeSetup()
        try await s.messages.save(MessageRecord(
            id: "m2", conversationId: "c1", role: .assistant, content: "more", createdAt: now.addingTimeInterval(60)
        ))
        try await s.tools.save(ToolCallRecord(
            id: "tc1", messageId: "m1", conversationId: "c1", toolName: "todo.list",
            parameters: "{}", status: .pending, createdAt: now
        ))
        try await s.tools.save(ToolCallRecord(
            id: "tc2", messageId: "m2", conversationId: "c1", toolName: "todo.create",
            parameters: "{}", status: .pending, createdAt: now
        ))

        #expect(try await s.tools.fetchByMessage("m1").map(\.id) == ["tc1"])
        #expect(try await s.tools.fetchByMessage("m2").map(\.id) == ["tc2"])
    }

    @Test func fetchByConversationOrdersByCreatedAt() async throws {
        let s = try await makeSetup()
        try await s.tools.save(ToolCallRecord(
            id: "tc_late", messageId: "m1", conversationId: "c1", toolName: "x",
            parameters: "{}", status: .pending, createdAt: now.addingTimeInterval(60)
        ))
        try await s.tools.save(ToolCallRecord(
            id: "tc_early", messageId: "m1", conversationId: "c1", toolName: "y",
            parameters: "{}", status: .pending, createdAt: now
        ))

        let rows = try await s.tools.fetchByConversation("c1")
        #expect(rows.map(\.id) == ["tc_early", "tc_late"])
    }

    @Test func fetchByStatusFiltersAcrossConversations() async throws {
        let s = try await makeSetup()
        try await s.conversations.save(ConversationRecord(
            id: "c2", title: "Other", createdAt: now, updatedAt: now
        ))
        try await s.messages.save(MessageRecord(
            id: "m_c2", conversationId: "c2", role: .assistant, content: "x", createdAt: now
        ))

        try await s.tools.save(ToolCallRecord(
            id: "tc_pending_c1", messageId: "m1", conversationId: "c1", toolName: "x",
            parameters: "{}", status: .pending, createdAt: now
        ))
        try await s.tools.save(ToolCallRecord(
            id: "tc_failed_c1", messageId: "m1", conversationId: "c1", toolName: "y",
            parameters: "{}", status: .failed, createdAt: now
        ))
        try await s.tools.save(ToolCallRecord(
            id: "tc_pending_c2", messageId: "m_c2", conversationId: "c2", toolName: "z",
            parameters: "{}", status: .pending, createdAt: now
        ))

        let pending = try await s.tools.fetchByStatus(.pending)
        #expect(Set(pending.map(\.id)) == Set(["tc_pending_c1", "tc_pending_c2"]))

        let failed = try await s.tools.fetchByStatus(.failed)
        #expect(failed.map(\.id) == ["tc_failed_c1"])
    }

    @Test func updateStatusFlipsStateAndRecordsResult() async throws {
        let s = try await makeSetup()
        try await s.tools.save(ToolCallRecord(
            id: "tc1", messageId: "m1", conversationId: "c1", toolName: "todo.create",
            parameters: "{\"title\":\"x\"}", status: .pending, createdAt: now
        ))

        let completed = now.addingTimeInterval(2)
        try await s.tools.updateStatus(
            id: "tc1", status: .success, result: "{\"id\":\"42\"}", completedAt: completed
        )

        let row = try await s.tools.fetch(id: "tc1")
        #expect(row?.status == .success)
        #expect(row?.result == "{\"id\":\"42\"}")
        #expect(row?.completedAt == completed)
    }

    @Test func updateStatusOnUnknownIDIsNoOp() async throws {
        let s = try await makeSetup()
        try await s.tools.updateStatus(
            id: "missing", status: .failed, result: nil, completedAt: now
        )
        #expect(try await s.tools.fetch(id: "missing") == nil)
    }

    @Test func cascadingMessageDeleteRemovesToolCalls() async throws {
        let s = try await makeSetup()
        try await s.tools.save(ToolCallRecord(
            id: "tc1", messageId: "m1", conversationId: "c1", toolName: "x",
            parameters: "{}", status: .pending, createdAt: now
        ))

        _ = try await s.database.queue.write { db in
            try MessageRecord.deleteOne(db, key: "m1")
        }

        #expect(try await s.tools.fetch(id: "tc1") == nil)
    }
}
