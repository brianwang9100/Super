#if canImport(UIKit)
import Core
import Foundation
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Top-level screen snapshots. Each scenario constructs the view model
/// with a no-op driver and stub repositories so the view renders entirely
/// from in-memory state — no GRDB, no network. The empty-state greeting
/// is pinned to a fixed afternoon timestamp so baselines don't drift
/// across the morning/afternoon/evening hour buckets at record time.
@Suite("ChatScreen snapshots", .serialized)
@MainActor
struct ChatScreenSnapshotTests {
    private let model = LLMModel(
        id: "gpt-4o",
        displayName: "GPT-4o",
        supportsThinking: false,
        supportsTools: true,
        maxContextTokens: 128_000
    )

    /// Wed 2026-01-14 14:00:00 UTC — sits squarely in the "afternoon"
    /// hour bucket regardless of the system calendar in use. Pinning the
    /// clock removes the wall-clock drift that previously forced baseline
    /// re-records every time the suite ran in a different hour bucket.
    private let snapshotClock = FixedClock(Date(timeIntervalSince1970: 1_768_485_600))

    @Test("empty state in light theme")
    func emptyLight() {
        verifyEmpty(theme: .light, name: "screen_empty_light")
    }

    @Test("empty state in dark theme")
    func emptyDark() {
        verifyEmpty(theme: .dark, name: "screen_empty_dark")
    }

    @Test("empty state in sepia theme")
    func emptySepia() {
        verifyEmpty(theme: .sepia, name: "screen_empty_sepia")
    }

    @Test("populated transcript in light theme")
    func populatedLight() {
        verifyPopulated(theme: .light, name: "screen_populated_light")
    }

    @Test("populated transcript in dark theme")
    func populatedDark() {
        verifyPopulated(theme: .dark, name: "screen_populated_dark")
    }

    @Test("populated transcript at dynamic type XXL")
    func populatedXXL() {
        let function = #function
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let messages: [MessageRecord] = [
            MessageRecord(id: "u1", conversationId: "c", role: .user, content: "What can you do?", createdAt: now),
            MessageRecord(id: "a1", conversationId: "c", role: .assistant, content: "I can answer questions, write code, and use a few built-in tools.", createdAt: now.addingTimeInterval(1)),
        ]
        let viewModel = makeViewModel(initialMessages: messages)
        viewModel._setSnapshotState(
            items: ChatScreenViewModel.project(messages: messages, toolCalls: [], checkpoint: nil),
            usedTokens: 1_200
        )

        let view = ChatScreen(viewModel: viewModel, clock: snapshotClock)
            .superTheme(.make(.light))
            .dynamicTypeSize(.xxLarge)
            .frame(width: 402, height: 874)
        recordOrCompare(view: view, name: "screen_populated_light_xxl", function: function)
    }

    private func verifyEmpty(
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let viewModel = makeViewModel(initialMessages: [])
        let view = ChatScreen(viewModel: viewModel, clock: snapshotClock)
            .superTheme(.make(theme))
            .frame(width: 402, height: 874)

        recordOrCompare(view: view, name: name, function: function)
    }

    private func verifyPopulated(
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let messages: [MessageRecord] = [
            MessageRecord(id: "u1", conversationId: "c", role: .user, content: "What can you do?", createdAt: now),
            MessageRecord(id: "a1", conversationId: "c", role: .assistant, content: "I can answer questions, write code, and use a few built-in tools.", createdAt: now.addingTimeInterval(1)),
        ]
        let viewModel = makeViewModel(initialMessages: messages)
        viewModel._setSnapshotState(
            items: ChatScreenViewModel.project(messages: messages, toolCalls: [], checkpoint: nil),
            usedTokens: 1_200
        )

        let view = ChatScreen(viewModel: viewModel, clock: snapshotClock)
            .superTheme(.make(theme))
            .frame(width: 402, height: 874)
        recordOrCompare(view: view, name: name, function: function)
    }

    private func makeViewModel(initialMessages: [MessageRecord]) -> ChatScreenViewModel {
        let driver = NoopDriver()
        let messages = SnapshotMessageRepository(rows: initialMessages)
        let toolCalls = SnapshotToolCallRepository()
        let checkpoints = SnapshotCheckpointRepository()
        return ChatScreenViewModel(
            conversationId: "c",
            conversationTitle: "New chat",
            driver: driver,
            messageRepository: messages,
            toolCallRepository: toolCalls,
            checkpointRepository: checkpoints,
            availableModels: [model]
        )
    }

    private func recordOrCompare<V: View>(
        view: V,
        name: String,
        function: String = #function
    ) {
        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 874)),
            named: name,
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}

private struct NoopDriver: ChatSessionDriver {
    func send(text: String, model: LLMModel) async -> AsyncStream<ChatEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

private actor SnapshotMessageRepository: MessageRepository {
    private var rows: [MessageRecord]
    init(rows: [MessageRecord]) { self.rows = rows }
    func fetchAll(conversationId: String) async throws -> [MessageRecord] {
        rows.filter { $0.conversationId == conversationId }
    }
    func fetch(id: String) async throws -> MessageRecord? { rows.first { $0.id == id } }
    func save(_ record: MessageRecord) async throws { rows.append(record) }
    func deleteAll(conversationId: String) async throws {
        rows.removeAll { $0.conversationId == conversationId }
    }
}

private actor SnapshotToolCallRepository: ToolCallRepository {
    private var rows: [ToolCallRecord] = []
    func fetchByConversation(_ conversationId: String) async throws -> [ToolCallRecord] {
        rows.filter { $0.conversationId == conversationId }
    }
    func fetchByMessage(_ messageId: String) async throws -> [ToolCallRecord] {
        rows.filter { $0.messageId == messageId }
    }
    func fetchByStatus(_ status: ToolCallStatus) async throws -> [ToolCallRecord] {
        rows.filter { $0.status == status }
    }
    func fetch(id: String) async throws -> ToolCallRecord? { rows.first { $0.id == id } }
    func save(_ record: ToolCallRecord) async throws { rows.append(record) }
    func updateStatus(id: String, status: ToolCallStatus, result: String?, completedAt: Date?) async throws {}
}

private actor SnapshotCheckpointRepository: CompactionCheckpointRepository {
    func liveCheckpoint(for conversationId: String) async throws -> CompactionCheckpointRecord? { nil }
    func all(for conversationId: String) async throws -> [CompactionCheckpointRecord] { [] }
    func save(_ record: CompactionCheckpointRecord) async throws {}
}
#endif
