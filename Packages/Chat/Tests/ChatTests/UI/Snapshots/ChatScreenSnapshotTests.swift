#if canImport(UIKit)
import Core
import Foundation
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Chat

@Suite("ChatScreen snapshots", .serialized)
@MainActor
struct ChatScreenSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    private let model = LLMModel(
        id: "gpt-4o",
        displayName: "GPT-4o",
        supportsThinking: false,
        supportsTools: true,
        maxContextTokens: 128_000
    )

    @Test("empty state in light theme")
    func emptyLight() {
        verifyEmpty(theme: .vellumLight, name: "screen_empty_light")
    }

    @Test("empty state in dark theme")
    func emptyDark() {
        verifyEmpty(theme: .vellumDark, name: "screen_empty_dark")
    }

    @Test("empty state with suggested actions, light")
    func emptyWithActionsLight() {
        verifyEmptyWithActions(theme: .vellumLight, name: "screen_empty_actions_light")
    }

    @Test("empty state with suggested actions, dark")
    func emptyWithActionsDark() {
        verifyEmptyWithActions(theme: .vellumDark, name: "screen_empty_actions_dark")
    }

    @Test("empty state with suggested actions at dynamic type XXL")
    func emptyWithActionsXXL() {
        verifyEmptyWithActions(theme: .vellumLight, name: "screen_empty_actions_xxl", dynamicType: .xxLarge)
    }

    @Test("populated transcript in light theme")
    func populatedLight() {
        verifyPopulated(theme: .vellumLight, name: "screen_populated_light")
    }

    @Test("populated transcript in dark theme")
    func populatedDark() {
        verifyPopulated(theme: .vellumDark, name: "screen_populated_dark")
    }

    @Test("no-model error banner over empty state, light")
    func noModelErrorLight() {
        verifyNoModelError(theme: .vellumLight, name: "screen_no_model_error_light")
    }

    @Test("no-model error banner over empty state, dark")
    func noModelErrorDark() {
        verifyNoModelError(theme: .vellumDark, name: "screen_no_model_error_dark")
    }

    @Test("no-model error banner over empty state at dynamic type XXL")
    func noModelErrorEmptyXXL() {
        // With no transcript rows, the banner alone exercises wrapping and clipping.
        let function = #function
        let viewModel = ChatScreenViewModel(
            conversationId: "c",
            conversationTitle: "New chat",
            driver: NoopDriver(),
            messageRepository: SnapshotMessageRepository(rows: []),
            toolCallRepository: SnapshotToolCallRepository(),
            checkpointRepository: SnapshotCheckpointRepository(),
            availableModels: []
        )
        viewModel.composerText = "hi"
        viewModel.send("hi")

        let view = ChatScreen(viewModel: viewModel)
            .superTheme(.make(.vellumLight))
            .dynamicTypeSize(.xxLarge)
            .frame(width: 402, height: 874)
        recordOrCompareWithFontTolerance(view: view, name: "screen_no_model_error_empty_xxl", function: function)
    }

    @Test("no-model error banner over populated transcript, light")
    func noModelErrorPopulatedLight() {
        verifyNoModelErrorPopulated(theme: .vellumLight, name: "screen_no_model_error_populated_light")
    }

    @Test("no-model error banner over populated transcript, dark")
    func noModelErrorPopulatedDark() {
        verifyNoModelErrorPopulated(theme: .vellumDark, name: "screen_no_model_error_populated_dark")
    }

    // The combined populated/error/XXL fixture exceeds cross-runner font tolerance.
    // noModelErrorEmptyXXL covers the banner; populatedXXL covers transcript reflow.

    private func verifyNoModelErrorPopulated(
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let viewModel = makeNoModelErrorPopulatedViewModel()
        let view = ChatScreen(viewModel: viewModel)
            .superTheme(.make(theme))
            .frame(width: 402, height: 874)
        recordOrCompareWithFontTolerance(view: view, name: name, function: function)
    }

    private func makeNoModelErrorPopulatedViewModel() -> ChatScreenViewModel {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let messages: [MessageRecord] = [
            MessageRecord(id: "u1", conversationId: "c", role: .user, content: "What can you do?", createdAt: now),
            MessageRecord(id: "a1", conversationId: "c", role: .assistant, content: "I can answer questions, write code, and use a few built-in tools.", createdAt: now.addingTimeInterval(1)),
        ]
        let viewModel = ChatScreenViewModel(
            conversationId: "c",
            conversationTitle: "New chat",
            driver: NoopDriver(),
            messageRepository: SnapshotMessageRepository(rows: messages),
            toolCallRepository: SnapshotToolCallRepository(),
            checkpointRepository: SnapshotCheckpointRepository(),
            availableModels: []
        )
        viewModel._setSnapshotState(
            items: ChatScreenViewModel.project(messages: messages, toolCalls: [], checkpoint: nil),
            usedTokens: 1_200,
            error: .noModelConfigured(onAddModel: {})
        )
        return viewModel
    }

    private func verifyNoModelError(
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let viewModel = ChatScreenViewModel(
            conversationId: "c",
            conversationTitle: "New chat",
            driver: NoopDriver(),
            messageRepository: SnapshotMessageRepository(rows: []),
            toolCallRepository: SnapshotToolCallRepository(),
            checkpointRepository: SnapshotCheckpointRepository(),
            availableModels: []
        )
        viewModel.composerText = "hi"
        viewModel.send("hi")

        let view = ChatScreen(viewModel: viewModel)
            .superTheme(.make(theme))
            .frame(width: 402, height: 874)
        recordOrCompareWithFontTolerance(view: view, name: name, function: function)
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

        let view = ChatScreen(viewModel: viewModel)
            .superTheme(.make(.vellumLight))
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
        let view = ChatScreen(viewModel: viewModel)
            .superTheme(.make(theme))
            .frame(width: 402, height: 874)

        // Scope tolerance to system-font chrome antialiasing across runners.
        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(precision: 0.99, perceptualPrecision: 0.97, layout: .fixed(width: 402, height: 874)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }

    private func verifyEmptyWithActions(
        theme: SuperTheme.Identifier,
        name: String,
        dynamicType: DynamicTypeSize = .large,
        function: String = #function
    ) {
        let actions = [
            SuggestedChatAction(label: "Explain a verse", message: "Explain a Bible verse to me."),
            SuggestedChatAction(label: "Today's reading", message: "What should I read in the Bible today?"),
            SuggestedChatAction(label: "Write a prayer", message: "Write a short prayer for me."),
        ]
        let viewModel = makeViewModel(initialMessages: [])
        // Set resolved suggestions and the async fallback to the same list.
        viewModel._setSnapshotSuggestions(actions)
        let view = ChatScreen(viewModel: viewModel)
            .environment(\.appletSuggestedChatActions, actions)
            .superTheme(.make(theme))
            .dynamicTypeSize(dynamicType)
            .frame(width: 402, height: 874)

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(precision: 0.99, perceptualPrecision: 0.97, layout: .fixed(width: 402, height: 874)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
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

        let view = ChatScreen(viewModel: viewModel)
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
            availableModels: [SelectableModel(model)]
        )
    }

    private func recordOrCompare<V: View>(
        view: V,
        name: String,
        function: String = #function
    ) {
        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 874)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }

    /// Tolerate cross-runner system-font antialiasing in error-banner fixtures.
    private func recordOrCompareWithFontTolerance<V: View>(
        view: V,
        name: String,
        function: String = #function
    ) {
        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(precision: 0.99, perceptualPrecision: 0.97, layout: .fixed(width: 402, height: 874)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}

private struct NoopDriver: ChatSessionDriver {
    func send(text: String, model: LLMModel, references: [RecordReference]) async -> AsyncStream<ChatEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func retry(model: LLMModel) async -> AsyncStream<ChatEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func subscribe() async -> (snapshot: ChatSession.LiveTurnSnapshot?, stream: AsyncStream<ChatEvent>) {
        let stream = AsyncStream<ChatEvent> { continuation in
            continuation.finish()
        }
        return (nil, stream)
    }

    func cancel() async {}
    func confirmToolCall(id: String) async {}
    func skipToolCall(id: String) async {}
}

private actor SnapshotMessageRepository: MessageRepository {
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
    func delete(ids: [String]) async throws {}
}
#endif
