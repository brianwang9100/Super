#if canImport(UIKit)
import Core
import Foundation
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Pixel-stable snapshots of `ChatOverlayContainer` in each of the three
/// `ChatPresentationState` shapes. M3 smoke: just light theme. The full
/// state × theme × backdrop matrix lands in M4.
@Suite("ChatOverlayContainer snapshots", .serialized)
@MainActor
struct ChatOverlayContainerSnapshotTests {
    private let model = LLMModel(
        id: "gpt-4o",
        displayName: "GPT-4o",
        supportsThinking: false,
        supportsTools: true,
        maxContextTokens: 128_000
    )

    private static let now = Date(timeIntervalSince1970: 1_750_000_000)
    private static let frame = CGSize(width: 402, height: 874)

    // MARK: - Expanded

    @Test("expanded — light")
    func expandedLight() {
        verify(state: .expanded, theme: .light, name: "overlay_expanded_light")
    }

    @Test("expanded — dark")
    func expandedDark() {
        verify(state: .expanded, theme: .dark, name: "overlay_expanded_dark")
    }

    @Test("expanded — sepia")
    func expandedSepia() {
        verify(state: .expanded, theme: .sepia, name: "overlay_expanded_sepia")
    }

    // MARK: - Semi-expanded

    @Test("semi-expanded — light")
    func semiExpandedLight() {
        verify(state: .semiExpanded, theme: .light, name: "overlay_semi_expanded_light")
    }

    @Test("semi-expanded — dark")
    func semiExpandedDark() {
        verify(state: .semiExpanded, theme: .dark, name: "overlay_semi_expanded_dark")
    }

    @Test("semi-expanded — sepia")
    func semiExpandedSepia() {
        verify(state: .semiExpanded, theme: .sepia, name: "overlay_semi_expanded_sepia")
    }

    // MARK: - Minimized

    @Test("minimized — light")
    func minimizedLight() {
        verify(state: .minimized, theme: .light, name: "overlay_minimized_light")
    }

    @Test("minimized — dark")
    func minimizedDark() {
        verify(state: .minimized, theme: .dark, name: "overlay_minimized_dark")
    }

    @Test("minimized — sepia")
    func minimizedSepia() {
        verify(state: .minimized, theme: .sepia, name: "overlay_minimized_sepia")
    }

    // MARK: - Helpers

    private func verify(
        state: ChatPresentationState,
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let messages: [MessageRecord] = [
            MessageRecord(id: "u1", conversationId: "c", role: .user, content: "What can you do?", createdAt: Self.now),
            MessageRecord(id: "a1", conversationId: "c", role: .assistant, content: "I can answer questions, write code, and use a few built-in tools.", createdAt: Self.now.addingTimeInterval(1)),
        ]
        let viewModel = makeViewModel(initialMessages: messages)
        viewModel._setSnapshotState(
            items: ChatScreenViewModel.project(messages: messages, toolCalls: [], checkpoint: nil),
            usedTokens: 1_200
        )

        let view = ChatOverlayContainer(
            state: .constant(state),
            viewModel: viewModel
        )
        .superTheme(.make(theme))
        .frame(width: Self.frame.width, height: Self.frame.height)

        // Slight precision tolerance — the chat overlay's translucent
        // surface and blurred backdrop produce sub-pixel anti-aliasing
        // around the rounded corners that's runtime-stable but not
        // pixel-identical across recording sessions.
        let failure = verifySnapshot(
            of: view,
            as: .image(precision: 0.99, perceptualPrecision: 0.97, layout: .fixed(width: Self.frame.width, height: Self.frame.height)),
            named: name,
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }

    private func makeViewModel(initialMessages: [MessageRecord]) -> ChatScreenViewModel {
        let driver = OverlayNoopDriver()
        let messages = OverlayMessageRepository(rows: initialMessages)
        let toolCalls = OverlayToolCallRepository()
        let checkpoints = OverlayCheckpointRepository()
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
}

// MARK: - Local snapshot helpers
//
// Mirrors the `NoopDriver` + `Snapshot*Repository` private helpers in
// `ChatScreenSnapshotTests.swift`. Inlined here because those types are
// file-private and the project doesn't yet have a shared snapshot-test
// helper module. Promotable to a single shared helper file in M4 if more
// suites need them.

private struct OverlayNoopDriver: ChatSessionDriver {
    func send(text: String, model: LLMModel) async -> AsyncStream<ChatEvent> {
        AsyncStream { continuation in continuation.finish() }
    }
    func subscribe() async -> (snapshot: ChatSession.LiveTurnSnapshot?, stream: AsyncStream<ChatEvent>) {
        let stream = AsyncStream<ChatEvent> { continuation in continuation.finish() }
        return (nil, stream)
    }
    func cancel() async {}
}

private actor OverlayMessageRepository: MessageRepository {
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

private actor OverlayToolCallRepository: ToolCallRepository {
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

private actor OverlayCheckpointRepository: CompactionCheckpointRepository {
    func liveCheckpoint(for conversationId: String) async throws -> CompactionCheckpointRecord? { nil }
    func all(for conversationId: String) async throws -> [CompactionCheckpointRecord] { [] }
    func save(_ record: CompactionCheckpointRecord) async throws {}
}
#endif
