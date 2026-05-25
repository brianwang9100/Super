#if canImport(UIKit)
import Core
import Foundation
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Pixel-stable snapshots of the morphing `ChatOverlay`. Replaces the
/// prior `ChatOverlayContainerSnapshotTests`, which captured three
/// discrete view hierarchies. The morphing overlay is one continuous
/// surface, so we sample it at:
///
/// - the three settled anchors (`.expanded` / `.semiExpanded` /
///   `.minimized`), driven by `state:` only,
/// - one mid-drag intermediate height between minimized and
///   semi-expanded so the composer morph (label → editor, footer fade)
///   is on a baseline.
///
/// All four sample points × three themes for the settled anchors;
/// light only for the mid-drag baseline (the morph timing matters far
/// more than per-theme color matching at the intermediate point).
// `.serialized` — snapshot baselines are read/written per-test against
// the same on-disk `__Snapshots__/ChatOverlaySnapshotTests/` directory.
// Parallel execution races on the PNG files (TOCTOU), not on any async
// behavior in the code under test — serialization is the right tool.
@Suite("ChatOverlay snapshots", .serialized)
@MainActor
struct ChatOverlaySnapshotTests {
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

    // MARK: - Mid-drag morph

    /// Pins the chat surface at ≈ 22% of the way from minimized to
    /// expanded — well into the composer's cross-fade band so the pill
    /// label has faded out (≈ progress 0.2) but the footer has only
    /// just begun to appear (≈ progress 0.15 → 0.45 fade-in). This
    /// baseline catches regressions in the smoothstep timings that the
    /// settled-anchor snapshots can't see.
    @Test("mid-drag intermediate height — light")
    func midDragLight() {
        let viewModel = makeViewModel(initialMessages: populatedMessages)
        viewModel._setSnapshotState(
            items: ChatScreenViewModel.project(messages: populatedMessages, toolCalls: [], checkpoint: nil),
            usedTokens: 1_200
        )

        // Minimized base height (60pt) + 0.22 × (full-height 874 − 60)
        // ≈ 239pt. Inside the composer's morph band; transcript is
        // visible at low opacity.
        let view = ChatOverlay(
            state: .constant(.minimized),
            viewModel: viewModel,
            _injectedDragHeight: 240
        )
        .superTheme(.make(.light))
        .frame(width: Self.frame.width, height: Self.frame.height)

        let failure = verifySnapshot(
            of: view,
            as: .image(precision: 0.99, perceptualPrecision: 0.97, layout: .fixed(width: Self.frame.width, height: Self.frame.height)),
            named: "overlay_mid_drag_light",
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: #function
        )
        if let failure {
            Issue.record("overlay_mid_drag_light: \(failure)")
        }
    }

    // MARK: - Semi-expanded with the keyboard-aware height frozen
    //
    // `_injectedKeyboardAwareHeight: 538` mimics the value the live
    // `GeometryReader` produces when a 336pt iPhone keyboard is up.
    // Under the canonical-safeAreaInset architecture this value
    // feeds only the drag-math clamps (`updateDrag` / `endDrag`),
    // **not** the rendered chat-surface height — that's now
    // `geo.size.height` so the surface fills the device top-to-bottom
    // and the composer rides SwiftUI's safe-area inset at runtime.
    // The snapshot therefore can't show the real "keyboard up" visual
    // (no real keyboard, no SwiftUI keyboard-avoidance fires); it
    // captures the drag-math-frozen render: full-height surface with
    // composer pinned at the device bottom. Useful as a regression
    // baseline for things like header/handle positioning at the
    // semi-expanded settled anchor when the drag math is constrained.
    // True keyboard-up visual is covered by on-device verification.
    @Test("semi-expanded with the keyboard up — light")
    func semiExpandedKeyboardLight() {
        verifyKeyboardSemi(theme: .light, name: "overlay_semi_expanded_keyboard_light")
    }

    @Test("semi-expanded with the keyboard up — dark")
    func semiExpandedKeyboardDark() {
        verifyKeyboardSemi(theme: .dark, name: "overlay_semi_expanded_keyboard_dark")
    }

    @Test("semi-expanded with the keyboard up — sepia")
    func semiExpandedKeyboardSepia() {
        verifyKeyboardSemi(theme: .sepia, name: "overlay_semi_expanded_keyboard_sepia")
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
// helper module. Promotable to a single shared helper file if more
// suites need them.

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
