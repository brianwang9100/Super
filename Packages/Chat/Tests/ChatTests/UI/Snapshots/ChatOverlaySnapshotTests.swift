#if canImport(UIKit)
import Core
import Foundation
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Chat

@Suite("ChatOverlay snapshots", .serialized)
@MainActor
struct ChatOverlaySnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

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
        verify(state: .expanded, theme: .vellumLight, name: "overlay_expanded_light")
    }

    @Test("expanded — dark")
    func expandedDark() {
        verify(state: .expanded, theme: .vellumDark, name: "overlay_expanded_dark")
    }

    // MARK: - Semi-expanded

    @Test("semi-expanded — light")
    func semiExpandedLight() {
        verify(state: .semiExpanded, theme: .vellumLight, name: "overlay_semi_expanded_light")
    }

    @Test("semi-expanded — dark")
    func semiExpandedDark() {
        verify(state: .semiExpanded, theme: .vellumDark, name: "overlay_semi_expanded_dark")
    }

    // MARK: - Minimized

    @Test("minimized — light")
    func minimizedLight() {
        verify(state: .minimized, theme: .vellumLight, name: "overlay_minimized_light")
    }

    @Test("minimized — dark")
    func minimizedDark() {
        verify(state: .minimized, theme: .vellumDark, name: "overlay_minimized_dark")
    }

    // MARK: - Mid-drag morph

    /// Sample the composer cross-fade that settled anchors cannot expose.
    @Test("mid-drag intermediate height — light")
    func midDragLight() {
        let viewModel = makeViewModel(initialMessages: populatedMessages)
        viewModel._setSnapshotState(
            items: ChatScreenViewModel.project(messages: populatedMessages, toolCalls: [], checkpoint: nil),
            usedTokens: 1_200
        )

        let view = ChatOverlay(
            state: .constant(.minimized),
            viewModel: viewModel,
            _injectedDragHeight: 240
        )
        .superTheme(.make(.vellumLight))
        .frame(width: Self.frame.width, height: Self.frame.height)

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(precision: 0.99, perceptualPrecision: 0.97, layout: .fixed(width: Self.frame.width, height: Self.frame.height)),
            named: "overlay_mid_drag_light",
            testName: #function
        )
        if let failure {
            Issue.record("overlay_mid_drag_light: \(failure)")
        }
    }

    // MARK: - Keyboard-up semi-expanded

    /// Constrain the outer region to model keyboard space and check header/composer positions.
    @Test("semi-expanded with the keyboard up — light")
    func semiExpandedKeyboardLight() {
        verifyKeyboardSemi(theme: .vellumLight, name: "overlay_semi_expanded_keyboard_light")
    }

    @Test("semi-expanded with the keyboard up — dark")
    func semiExpandedKeyboardDark() {
        verifyKeyboardSemi(theme: .vellumDark, name: "overlay_semi_expanded_keyboard_dark")
    }

    private func verifyKeyboardSemi(
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let viewModel = makeViewModel(initialMessages: populatedMessages)
        viewModel._setSnapshotState(
            items: ChatScreenViewModel.project(messages: populatedMessages, toolCalls: [], checkpoint: nil),
            usedTokens: 1_200
        )

        let view = ChatOverlay(
            state: .constant(.semiExpanded),
            viewModel: viewModel,
            _injectedKeyboardAwareHeight: 538
        )
        .superTheme(.make(theme))
        .frame(width: Self.frame.width, height: Self.frame.height)

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(precision: 0.99, perceptualPrecision: 0.97, layout: .fixed(width: Self.frame.width, height: Self.frame.height)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }

    // MARK: - Helpers

    private var populatedMessages: [MessageRecord] {
        [
            MessageRecord(id: "u1", conversationId: "c", role: .user, content: "What can you do?", createdAt: Self.now),
            MessageRecord(id: "a1", conversationId: "c", role: .assistant, content: "I can answer questions, write code, and use a few built-in tools.", createdAt: Self.now.addingTimeInterval(1)),
        ]
    }

    private func verify(
        state: ChatPresentationState,
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let messages = populatedMessages
        let viewModel = makeViewModel(initialMessages: messages)
        viewModel._setSnapshotState(
            items: ChatScreenViewModel.project(messages: messages, toolCalls: [], checkpoint: nil),
            usedTokens: 1_200
        )

        let view = ChatOverlay(
            state: .constant(state),
            viewModel: viewModel
        )
        .superTheme(.make(theme))
        .frame(width: Self.frame.width, height: Self.frame.height)

        // Translucent rounded edges need tolerance for cross-runner antialiasing drift.
        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(precision: 0.99, perceptualPrecision: 0.97, layout: .fixed(width: Self.frame.width, height: Self.frame.height)),
            named: name,
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
            availableModels: [SelectableModel(model)]
        )
    }
}

// MARK: - Local snapshot helpers

private struct OverlayNoopDriver: ChatSessionDriver {
    func send(text: String, model: LLMModel, references: [RecordReference]) async -> AsyncStream<ChatEvent> {
        AsyncStream { continuation in continuation.finish() }
    }
    func retry(model: LLMModel) async -> AsyncStream<ChatEvent> {
        AsyncStream { continuation in continuation.finish() }
    }
    func subscribe() async -> (snapshot: ChatSession.LiveTurnSnapshot?, stream: AsyncStream<ChatEvent>) {
        let stream = AsyncStream<ChatEvent> { continuation in continuation.finish() }
        return (nil, stream)
    }
    func cancel() async {}
    func confirmToolCall(id: String) async {}
    func skipToolCall(id: String) async {}
}

private actor OverlayMessageRepository: MessageRepository {
    private var rows: [MessageRecord]
    init(rows: [MessageRecord]) { self.rows = rows }
    func fetchAll(conversationId: String) async throws -> [MessageRecord] {
        rows.filter { $0.conversationId == conversationId }
    }
    func fetch(id: String) async throws -> MessageRecord? { rows.first { $0.id == id } }
    func hasUserMessage(conversationId: String) async throws -> Bool {
        rows.contains { $0.conversationId == conversationId && $0.role == .user }
    }
    func save(_ record: MessageRecord) async throws { rows.append(record) }
    func delete(ids: [String]) async throws {
        rows.removeAll { ids.contains($0.id) }
    }
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
    func delete(ids: [String]) async throws {}
}
#endif
