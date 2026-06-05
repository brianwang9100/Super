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
    init() { SnapshotFontRegistration.ensureRegistered() }

    private let model = LLMModel(
        id: "gpt-4o",
        displayName: "GPT-4o",
        supportsThinking: false,
        supportsTools: true,
        maxContextTokens: 128_000
    )

    /// Wed 2026-01-14 14:00:00 UTC — sits squarely in the "afternoon"
    /// hour bucket *when interpreted in UTC*. Pinning the clock removes
    /// wall-clock drift; pairing it with `snapshotCalendar` below
    /// removes timezone drift (PDT/UTC) between developer machines and
    /// CI runners, which previously rendered a different greeting.
    private let snapshotClock = FixedClock(Date(timeIntervalSince1970: 1_768_485_600))

    /// UTC calendar so the empty-state greeting's hour-of-day lookup
    /// is identical on any machine that runs this suite. Without this,
    /// 14:00 UTC lands in the "afternoon" bucket on a UTC sim and the
    /// "morning" bucket on a PDT sim — and the baselines diverge.
    private let snapshotCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

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

    @Test("populated transcript in sepia theme")
    func populatedSepia() {
        verifyPopulated(theme: .sepia, name: "screen_populated_sepia")
    }

    @Test("no-model error banner over empty state, light")
    func noModelErrorLight() {
        verifyNoModelError(theme: .light, name: "screen_no_model_error_light")
    }

    @Test("no-model error banner over empty state, dark")
    func noModelErrorDark() {
        verifyNoModelError(theme: .dark, name: "screen_no_model_error_dark")
    }

    @Test("no-model error banner over empty state, sepia")
    func noModelErrorSepia() {
        verifyNoModelError(theme: .sepia, name: "screen_no_model_error_sepia")
    }

    @Test("no-model error banner over empty state at dynamic type XXL")
    func noModelErrorEmptyXXL() {
        // Banner layout on an empty transcript at XXL exercises a
        // different `MessageList` height path than the populated XXL
        // variant: with zero rows the banner is the only content, so
        // its wrap/clip behavior is what's under test here.
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

        let view = ChatScreen(viewModel: viewModel, clock: snapshotClock, calendar: snapshotCalendar)
            .superTheme(.make(.light))
            .dynamicTypeSize(.xxLarge)
            .frame(width: 402, height: 874)
        recordOrCompareWithFontTolerance(view: view, name: "screen_no_model_error_empty_xxl", function: function)
    }

    @Test("no-model error banner over populated transcript, light")
    func noModelErrorPopulatedLight() {
        verifyNoModelErrorPopulated(theme: .light, name: "screen_no_model_error_populated_light")
    }

    @Test("no-model error banner over populated transcript, dark")
    func noModelErrorPopulatedDark() {
        verifyNoModelErrorPopulated(theme: .dark, name: "screen_no_model_error_populated_dark")
    }

    @Test("no-model error banner over populated transcript, sepia")
    func noModelErrorPopulatedSepia() {
        verifyNoModelErrorPopulated(theme: .sepia, name: "screen_no_model_error_populated_sepia")
    }

    // The populated-transcript + no-model-error state at Dynamic Type
    // XXL is intentionally not snapshotted. Per AGENTS.md §Testing
    // rule 5, "Dynamic Type XXL and other accessibility-large variants
    // are the ones most likely to fail and are the candidates for
    // deferral." Empirically this fixture exhibits sub-pixel anti-
    // aliasing drift across every text glyph between the local Mac
    // and the macos-26 CI runner (>1% pixels diff at perceptual
    // delta) — beyond what the `verifyEmpty`-style tolerance allows.
    // XXL coverage for the new state is provided by
    // `noModelErrorEmptyXXL`; the populated/XXL combination's
    // layout invariants are already covered by `populatedXXL`.

    private func verifyNoModelErrorPopulated(
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        // Reachable in production when the user previously chatted, then
        // deleted every model endpoint in Settings, then tried to send
        // again — the persisted transcript stays on screen while the
        // banner overlays the latest exchange. `availableModels` is
        // empty so the composer's model pill correctly reads
        // "No model", consistent with the banner state.
        let viewModel = makeNoModelErrorPopulatedViewModel()
        let view = ChatScreen(viewModel: viewModel, clock: snapshotClock, calendar: snapshotCalendar)
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
        // Fresh build: zero models configured, user typed something and
        // tapped send. `ChatScreenViewModel.send` sets the no-model error;
        // `ChatScreen.content` switches from the empty-state greeting to
        // `MessageList` so the banner renders above the composer.
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

        let view = ChatScreen(viewModel: viewModel, clock: snapshotClock, calendar: snapshotCalendar)
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

        let view = ChatScreen(viewModel: viewModel, clock: snapshotClock, calendar: snapshotCalendar)
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
        let view = ChatScreen(viewModel: viewModel, clock: snapshotClock, calendar: snapshotCalendar)
            .superTheme(.make(theme))
            .frame(width: 402, height: 874)

        // The empty state's `Instrument Serif` greeting renders with
        // small sub-pixel differences between iOS 26.2 (CI's pre-installed
        // simulator runtime, bundled with Xcode 26.3) and iOS 26.3 (the
        // local recording runtime). System-font surfaces don't drift;
        // only the custom serif body does. Allow a small fraction of
        // pixels (the anti-aliasing fringes around glyph edges) to differ
        // — and within those, accept a small perceptual delta. Scoped to
        // `verifyEmpty` so the rest of the suite stays pixel-exact.
        let failure = verifySnapshot(
            of: view,
            as: .image(precision: 0.99, perceptualPrecision: 0.97, layout: .fixed(width: 402, height: 874)),
            named: name,
            record: SnapshotEnvironment.isRecording ? .all : nil,
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

        let view = ChatScreen(viewModel: viewModel, clock: snapshotClock, calendar: snapshotCalendar)
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

    /// Snapshot comparison with the same precision tolerance used by
    /// `verifyEmpty` — accepts a small fraction of pixels differing
    /// within a small perceptual delta. Empirically required for the
    /// `noModelError*` family because the chat header (system font at
    /// small size) and the composer placeholder ("Chat with Super" / "Ask
    /// anything") drift by a sub-pixel amount between the local-recording
    /// Mac and the macos-26 CI runner. The rest of the suite (existing
    /// `populated`/`empty` baselines) renders byte-equal — only the
    /// error-banner fixtures expose this drift. Scoped narrowly so the
    /// rest of the suite stays pixel-exact.
    private func recordOrCompareWithFontTolerance<V: View>(
        view: V,
        name: String,
        function: String = #function
    ) {
        let failure = verifySnapshot(
            of: view,
            as: .image(precision: 0.99, perceptualPrecision: 0.97, layout: .fixed(width: 402, height: 874)),
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
