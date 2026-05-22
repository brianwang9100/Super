import Foundation
import Testing
@testable import Chat

/// Tests for `GRDBMessageRepository` insert, ordered fetch, and conversation-
/// scoped delete.
@Suite("GRDBMessageRepository")
struct MessageRepositoryTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRepo() async throws -> (ChatDatabase, GRDBMessageRepository, GRDBConversationRepository) {
        let db = try ChatDatabase.makeInMemory()
        let conversations = GRDBConversationRepository(database: db)
        try await conversations.save(ConversationRecord(
            id: "c1", title: "T", createdAt: now, updatedAt: now
        ))
        return (db, GRDBMessageRepository(database: db), conversations)
    }

    @Test func fetchAllReturnsMessagesInChronologicalOrder() async throws {
        let (_, repo, _) = try await makeRepo()
        try await repo.save(MessageRecord(
            id: "m2", conversationId: "c1", role: .assistant, content: "second",
            createdAt: now.addingTimeInterval(10)
        ))
        try await repo.save(MessageRecord(
            id: "m1", conversationId: "c1", role: .user, content: "first",
            createdAt: now
        ))
        try await repo.save(MessageRecord(
            id: "m3", conversationId: "c1", role: .user, content: "third",
            createdAt: now.addingTimeInterval(20)
        ))

        let rows = try await repo.fetchAll(conversationId: "c1")
        #expect(rows.map(\.id) == ["m1", "m2", "m3"])
    }

    @Test func fetchAllScopesByConversation() async throws {
        let (_, repo, conversations) = try await makeRepo()
        try await conversations.save(ConversationRecord(
            id: "c2", title: "Other", createdAt: now, updatedAt: now
        ))

        try await repo.save(MessageRecord(
            id: "m1", conversationId: "c1", role: .user, content: "in c1", createdAt: now
        ))
        try await repo.save(MessageRecord(
            id: "m2", conversationId: "c2", role: .user, content: "in c2", createdAt: now
        ))

        #expect(try await repo.fetchAll(conversationId: "c1").map(\.id) == ["m1"])
        #expect(try await repo.fetchAll(conversationId: "c2").map(\.id) == ["m2"])
    }

    @Test func saveUpsertsExistingMessage() async throws {
        let (_, repo, _) = try await makeRepo()
        try await repo.save(MessageRecord(
            id: "m1", conversationId: "c1", role: .user, content: "draft", createdAt: now
        ))
        try await repo.save(MessageRecord(
            id: "m1", conversationId: "c1", role: .user, content: "final",
            createdAt: now, tokenCount: 4
        ))

        let row = try await repo.fetch(id: "m1")
        #expect(row?.content == "final")
        #expect(row?.tokenCount == 4)
    }

    @Test func toolResultMessagesPreserveToolCallID() async throws {
        let (_, repo, _) = try await makeRepo()
        try await repo.save(MessageRecord(
            id: "m_assistant",
            conversationId: "c1",
            role: .assistant,
            content: "calling tool",
            createdAt: now
        ))
        try await repo.save(MessageRecord(
            id: "m_result",
            conversationId: "c1",
            role: .tool,
            content: "{\"ok\":true}",
            toolCallId: "tc-1",
            createdAt: now.addingTimeInterval(1)
        ))

        let row = try await repo.fetch(id: "m_result")
        #expect(row?.role == .tool)
        #expect(row?.toolCallId == "tc-1")
    }

    @Test func hasUserMessageIsTrueOnlyWhenConversationHasAUserRow() async throws {
        let (_, repo, conversations) = try await makeRepo()
        try await conversations.save(ConversationRecord(
            id: "c2", title: "Other", createdAt: now, updatedAt: now
        ))

        // Empty conversation: false.
        #expect(try await repo.hasUserMessage(conversationId: "c1") == false)

        // Only an assistant row: false.
        try await repo.save(MessageRecord(
            id: "m1", conversationId: "c1", role: .assistant, content: "hi", createdAt: now
        ))
        #expect(try await repo.hasUserMessage(conversationId: "c1") == false)

        // User row added: true.
        try await repo.save(MessageRecord(
            id: "m2", conversationId: "c1", role: .user, content: "ping", createdAt: now.addingTimeInterval(1)
        ))
        #expect(try await repo.hasUserMessage(conversationId: "c1") == true)

        // Scoped to conversationId — a user row in `c2` doesn't leak into `c1`'s
        // answer and vice versa.
        try await repo.save(MessageRecord(
            id: "m3", conversationId: "c2", role: .user, content: "elsewhere", createdAt: now
        ))
        #expect(try await repo.hasUserMessage(conversationId: "c2") == true)
        #expect(try await repo.hasUserMessage(conversationId: "missing") == false)
    }

    @Test func deleteAllRemovesEveryMessageInConversation() async throws {
        let (_, repo, conversations) = try await makeRepo()
        try await conversations.save(ConversationRecord(
            id: "c2", title: "Keep", createdAt: now, updatedAt: now
        ))

        try await repo.save(MessageRecord(
            id: "m1", conversationId: "c1", role: .user, content: "x", createdAt: now
        ))
        try await repo.save(MessageRecord(
            id: "m2", conversationId: "c2", role: .user, content: "y", createdAt: now
        ))

        try await repo.deleteAll(conversationId: "c1")
        #expect(try await repo.fetchAll(conversationId: "c1").isEmpty)
        #expect(try await repo.fetchAll(conversationId: "c2").map(\.id) == ["m2"])
    }

    @Test func deleteRemovesOnlyTheGivenIds() async throws {
        // The Regenerate path calls `delete(ids:)` with the contiguous
        // tail of messages from the targeted assistant onward. Survivors
        // ahead of the trim must stay; the deleted ids must be gone in
        // a single round trip.
        let (_, repo, _) = try await makeRepo()
        try await repo.save(MessageRecord(
            id: "m1", conversationId: "c1", role: .user, content: "first", createdAt: now
        ))
        try await repo.save(MessageRecord(
            id: "m2", conversationId: "c1", role: .assistant, content: "second",
            createdAt: now.addingTimeInterval(1)
        ))
        try await repo.save(MessageRecord(
            id: "m3", conversationId: "c1", role: .user, content: "third",
            createdAt: now.addingTimeInterval(2)
        ))
        try await repo.save(MessageRecord(
            id: "m4", conversationId: "c1", role: .assistant, content: "fourth",
            createdAt: now.addingTimeInterval(3)
        ))

        try await repo.delete(ids: ["m2", "m3", "m4"])

        #expect(try await repo.fetchAll(conversationId: "c1").map(\.id) == ["m1"])
    }

    @Test func deleteWithEmptyIdsIsANoOp() async throws {
        let (_, repo, _) = try await makeRepo()
        try await repo.save(MessageRecord(
            id: "m1", conversationId: "c1", role: .user, content: "x", createdAt: now
        ))

        try await repo.delete(ids: [])

        #expect(try await repo.fetchAll(conversationId: "c1").map(\.id) == ["m1"])
    }

    @Test func deleteCascadesToToolCallRows() async throws {
        // The `toolCall.messageId` foreign key has `ON DELETE CASCADE`,
        // so a Regenerate trim removes the assistant message's tool-call
        // rows transitively. Worth pinning so the regen flow doesn't
        // need a second explicit `ToolCallRepository.delete(...)` call.
        let (db, repo, _) = try await makeRepo()
        let toolCalls = GRDBToolCallRepository(database: db)
        try await repo.save(MessageRecord(
            id: "m1", conversationId: "c1", role: .assistant, content: "calls", createdAt: now
        ))
        try await toolCalls.save(ToolCallRecord(
            id: "tc1",
            messageId: "m1",
            conversationId: "c1",
            toolName: "test",
            parameters: "{}",
            result: nil,
            status: .success,
            createdAt: now,
            completedAt: nil
        ))

        try await repo.delete(ids: ["m1"])

        #expect(try await toolCalls.fetch(id: "tc1") == nil)
    }
}
