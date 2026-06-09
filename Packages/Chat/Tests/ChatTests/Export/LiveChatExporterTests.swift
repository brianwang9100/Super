import Core
import Foundation
import Testing
@testable import Chat

/// Verifies `LiveChatExporter` assembles the archive from the repositories:
/// excludes soft-deleted and transient conversations, preserves ordering,
/// groups tool calls under their message, and decodes JSON-string columns
/// into real nested JSON.
@Suite("LiveChatExporter")
struct LiveChatExporterTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let exportedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Setup {
        let exporter: LiveChatExporter
        let conversations: GRDBConversationRepository
        let messages: GRDBMessageRepository
        let tools: GRDBToolCallRepository
    }

    private func makeSetup() throws -> Setup {
        let db = try ChatDatabase.makeInMemory()
        return Setup(
            exporter: LiveChatExporter(
                conversationRepository: GRDBConversationRepository(database: db),
                messageRepository: GRDBMessageRepository(database: db),
                toolCallRepository: GRDBToolCallRepository(database: db),
                clock: FixedClock(exportedAt)
            ),
            conversations: GRDBConversationRepository(database: db),
            messages: GRDBMessageRepository(database: db),
            tools: GRDBToolCallRepository(database: db)
        )
    }

    @Test("excludes soft-deleted and transient conversations")
    func excludesNonUserVisible() async throws {
        let s = try makeSetup()
        try await s.conversations.save(ConversationRecord(
            id: "live", title: "Live", createdAt: t0, updatedAt: t0
        ))
        try await s.conversations.save(ConversationRecord(
            id: "gone", title: "Deleted", createdAt: t0, updatedAt: t0,
            deletedAt: t0.addingTimeInterval(10)
        ))
        try await s.conversations.save(ConversationRecord(
            id: "transient", title: "Transient", kind: .transient, createdAt: t0, updatedAt: t0
        ))

        let archive = try await s.exporter.export()

        #expect(archive.conversations.map(\.id) == ["live"])
        #expect(archive.formatVersion == ChatArchive.currentFormatVersion)
        #expect(archive.exportedAt == exportedAt)
    }

    @Test("preserves conversation order (newest update first) and message order")
    func ordering() async throws {
        let s = try makeSetup()
        try await s.conversations.save(ConversationRecord(
            id: "older", title: "Older", createdAt: t0, updatedAt: t0
        ))
        try await s.conversations.save(ConversationRecord(
            id: "newer", title: "Newer", createdAt: t0, updatedAt: t0.addingTimeInterval(60)
        ))
        try await s.messages.save(MessageRecord(
            id: "m_first", conversationId: "older", role: .user, content: "hi", createdAt: t0
        ))
        try await s.messages.save(MessageRecord(
            id: "m_second", conversationId: "older", role: .assistant, content: "hello",
            createdAt: t0.addingTimeInterval(5)
        ))

        let archive = try await s.exporter.export()

        // listActive() orders by updatedAt descending.
        #expect(archive.conversations.map(\.id) == ["newer", "older"])
        let older = try #require(archive.conversations.first { $0.id == "older" })
        #expect(older.messages.map(\.id) == ["m_first", "m_second"])
        #expect(older.messages.map(\.role) == ["user", "assistant"])
    }

    @Test("groups tool calls under the correct message and decodes JSON columns")
    func toolCallsAndJSONDecoding() async throws {
        let s = try makeSetup()
        try await s.conversations.save(ConversationRecord(
            id: "c", title: "C", createdAt: t0, updatedAt: t0
        ))
        try await s.messages.save(MessageRecord(
            id: "m1", conversationId: "c", role: .assistant, content: "a", createdAt: t0
        ))
        try await s.messages.save(MessageRecord(
            id: "m2", conversationId: "c", role: .assistant, content: "b",
            createdAt: t0.addingTimeInterval(5)
        ))
        try await s.tools.save(ToolCallRecord(
            id: "tc1", messageId: "m1", conversationId: "c", toolName: "todo.create",
            parameters: #"{"title":"buy milk","count":2}"#,
            result: #"{"ok":true}"#,
            status: .success, createdAt: t0, completedAt: t0.addingTimeInterval(1)
        ))
        try await s.tools.save(ToolCallRecord(
            id: "tc2", messageId: "m2", conversationId: "c", toolName: "time.now",
            parameters: "{}", status: .pending, createdAt: t0.addingTimeInterval(5)
        ))

        let archive = try await s.exporter.export()
        let conversation = try #require(archive.conversations.first)
        let m1 = try #require(conversation.messages.first { $0.id == "m1" })
        let m2 = try #require(conversation.messages.first { $0.id == "m2" })

        #expect(m1.toolCalls.map(\.id) == ["tc1"])
        #expect(m2.toolCalls.map(\.id) == ["tc2"])

        let call = try #require(m1.toolCalls.first)
        #expect(call.toolName == "todo.create")
        #expect(call.status == "success")
        #expect(call.parameters == .object([
            "title": .string("buy milk"),
            "count": .int(2),
        ]))
        #expect(call.result == .object(["ok": .bool(true)]))
        #expect(m2.toolCalls.first?.result == nil)
    }

    @Test("empty database yields an archive with no conversations")
    func emptyDatabase() async throws {
        let s = try makeSetup()
        let archive = try await s.exporter.export()
        #expect(archive.conversations.isEmpty)
        #expect(archive.exportedAt == exportedAt)
    }
}
