#if canImport(UIKit)
import Core
import Foundation
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Pixel-stable snapshots of `SidebarDrawer` across themes and key states:
/// open + empty list, open + populated, open + active row highlighted,
/// open with one running spinner, plus a Dynamic Type XXL variant.
///
/// Each scenario embeds the drawer in a fixed-size container that mimics
/// the iPhone 17 chat surface so the leading 300pt drawer + scrim
/// composition matches what ships in production.
@Suite("SidebarDrawer snapshots", .serialized)
@MainActor
struct SidebarDrawerSnapshotTests {
    private let appInfo = SuperAppInfo(bundleName: "Super", version: "0.3.1", build: "1")

    private static let frame = CGSize(width: 402, height: 874)

    private static let now = Date(timeIntervalSince1970: 1_750_000_000)

    private static let sampleChats: [SidebarViewModel.ChatItem] = [
        .init(id: "c1", title: "Italy trip planning", updatedAt: now, running: false),
        .init(id: "c2", title: "Pizza dough timing", updatedAt: now.addingTimeInterval(-300), running: false),
        .init(id: "c3", title: "Quarterly review notes", updatedAt: now.addingTimeInterval(-3_600), running: false),
        .init(id: "c4", title: "An overly long conversation title that must ellipsis", updatedAt: now.addingTimeInterval(-7_200), running: false),
    ]

    @Test("open empty in light")
    func openEmptyLight() {
        verify(theme: .light, chats: [], activeId: nil, name: "sidebar_open_empty_light")
    }

    @Test("open populated in light")
    func openPopulatedLight() {
        verify(theme: .light, chats: Self.sampleChats, activeId: "c1", name: "sidebar_open_populated_light")
    }

    @Test("open populated in dark")
    func openPopulatedDark() {
        verify(theme: .dark, chats: Self.sampleChats, activeId: "c1", name: "sidebar_open_populated_dark")
    }

    @Test("open populated in sepia")
    func openPopulatedSepia() {
        verify(theme: .sepia, chats: Self.sampleChats, activeId: "c1", name: "sidebar_open_populated_sepia")
    }

    @Test("active row highlighted in dark")
    func activeRowHighlightedDark() {
        verify(theme: .dark, chats: Self.sampleChats, activeId: "c2", name: "sidebar_active_dark")
    }

    @Test("running spinner shows on streaming row")
    func runningSpinner() {
        var chats = Self.sampleChats
        chats[1] = .init(id: "c2", title: chats[1].title, updatedAt: chats[1].updatedAt, running: true)
        verify(theme: .light, chats: chats, activeId: "c1", name: "sidebar_running_light")
    }

    // AGENTS.md §Testing.2 calls for a Reduce Motion snapshot on any view
    // with animation. The drawer slides in via `.transition(.move(...))`
    // and the per-row `SpinnerRing` rotates via `withAnimation(...)`.
    // SwiftUI's `\.accessibilityReduceMotion` env value is read-only, so
    // we can't flip it from a test wrapper. The steady-state first frame
    // for both transitions is identical between motion-on and
    // motion-reduced (drawer fully in; spinner at rotation 0), so a
    // captured snapshot wouldn't detect a regression in the reduced-motion
    // branch even if we recorded one. Same gap is documented in
    // `MessageListSnapshotTests`. Tracked to revisit when a reliable
    // env-injection seam appears in a future SDK.

    @Test("dynamic type XXL light")
    func dynamicTypeXXL() {
        let function = #function
        let viewModel = SidebarViewModel(
            conversationRepository: NoopConversationRepository(),
            sessionStore: makeIsolatedStore()
        )
        viewModel._setSnapshotState(chats: Self.sampleChats, activeId: "c1")
        let view = SidebarDrawer(
            isPresented: .constant(true),
            viewModel: viewModel,
            appInfo: appInfo,
            userInitials: "BW",
            userName: "Brian Wang",
            onSelectConversation: { _ in },
            onNewChat: {},
            onOpenSettings: {},
            onSelectApplet: { _ in }
        )
        .superTheme(.make(.light))
        .dynamicTypeSize(.xxLarge)
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: "sidebar_open_populated_light_xxl", function: function)
    }

    /// Negative wiring test: chat rows intentionally don't track the chat
    /// font-scale slider. Inject the upper-bound knob and the baseline
    /// stays visually identical to `sidebar_open_populated_light` — if a
    /// future change reverts the `rowTitleBase` property back to
    /// `appearance.fontScale` multiplication this baseline will diverge,
    /// catching the regression the rest of the suite (which all runs at
    /// the default `fontScale == 1.0`) would silently miss.
    @Test("font scale max — sidebar rows do not grow")
    func fontScaleMaxRowsUnchanged() {
        let function = #function
        let viewModel = SidebarViewModel(
            conversationRepository: NoopConversationRepository(),
            sessionStore: makeIsolatedStore()
        )
        viewModel._setSnapshotState(chats: Self.sampleChats, activeId: "c1")
        let view = SidebarDrawer(
            isPresented: .constant(true),
            viewModel: viewModel,
            appInfo: appInfo,
            userInitials: "BW",
            userName: "Brian Wang",
            onSelectConversation: { _ in },
            onNewChat: {},
            onOpenSettings: {},
            onSelectApplet: { _ in }
        )
        .superTheme(.make(.light))
        .chatAppearance(ChatAppearance(fontScale: 1.20))
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: "sidebar_font_scale_max_light", function: function)
    }

    private func verify(
        theme: SuperTheme.Identifier,
        chats: [SidebarViewModel.ChatItem],
        activeId: String?,
        name: String,
        function: String = #function
    ) {
        let viewModel = SidebarViewModel(
            conversationRepository: NoopConversationRepository(),
            sessionStore: makeIsolatedStore()
        )
        viewModel._setSnapshotState(chats: chats, activeId: activeId)
        let view = SidebarDrawer(
            isPresented: .constant(true),
            viewModel: viewModel,
            appInfo: appInfo,
            userInitials: "BW",
            userName: "Brian Wang",
            onSelectConversation: { _ in },
            onNewChat: {},
            onOpenSettings: {},
            onSelectApplet: { _ in }
        )
        .superTheme(.make(theme))
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: name, function: function)
    }

    private func recordOrCompare<V: View>(
        view: V,
        name: String,
        function: String = #function
    ) {
        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: Self.frame.width, height: Self.frame.height)),
            named: name,
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }

    private func makeIsolatedStore() -> ChatSessionStore {
        ChatSessionStore(
            messageRepository: NoopMessageRepository(),
            toolCallRepository: NoopToolCallRepository(),
            checkpointRepository: NoopCheckpointRepository(),
            llmProviderRegistry: LLMProviderRegistry(),
            toolRegistry: ToolRegistry(enablementRepository: NoopEnablementRepository()),
            compactor: Compactor(
                llmProviderRegistry: LLMProviderRegistry(),
                checkpointRepository: NoopCheckpointRepository()
            )
        )
    }
}

private struct NoopConversationRepository: ConversationRepository {
    func listActive() async throws -> [ConversationRecord] { [] }
    func fetch(id: String) async throws -> ConversationRecord? { nil }
    func save(_ record: ConversationRecord) async throws {}
    func softDelete(id: String, at deletedAt: Date) async throws {}
    func hardDelete(id: String) async throws {}
}

private actor NoopMessageRepository: MessageRepository {
    func fetchAll(conversationId: String) async throws -> [MessageRecord] { [] }
    func fetch(id: String) async throws -> MessageRecord? { nil }
    func save(_ record: MessageRecord) async throws {}
    func deleteAll(conversationId: String) async throws {}
}

private actor NoopToolCallRepository: ToolCallRepository {
    func fetchByConversation(_ conversationId: String) async throws -> [ToolCallRecord] { [] }
    func fetchByMessage(_ messageId: String) async throws -> [ToolCallRecord] { [] }
    func fetchByStatus(_ status: ToolCallStatus) async throws -> [ToolCallRecord] { [] }
    func fetch(id: String) async throws -> ToolCallRecord? { nil }
    func save(_ record: ToolCallRecord) async throws {}
    func updateStatus(id: String, status: ToolCallStatus, result: String?, completedAt: Date?) async throws {}
}

private actor NoopCheckpointRepository: CompactionCheckpointRepository {
    func liveCheckpoint(for conversationId: String) async throws -> CompactionCheckpointRecord? { nil }
    func all(for conversationId: String) async throws -> [CompactionCheckpointRecord] { [] }
    func save(_ record: CompactionCheckpointRecord) async throws {}
}

private actor NoopEnablementRepository: ToolEnablementRepository {
    func isEnabled(toolID: String) async throws -> Bool? { nil }
    func setEnabled(toolID: String, enabled: Bool) async throws {}
    func allEnabled() async throws -> [String: Bool] { [:] }
}
#endif
