#if canImport(UIKit)
import Core
import Foundation
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Chat

@Suite("SidebarDrawer snapshots", .serialized)
@MainActor
struct SidebarDrawerSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }
    private let appInfo = SuperAppInfo(bundleName: "Super", version: "0.3.1", build: "1")

    private static let frame = CGSize(width: 402, height: 874)

    private static let now = Date(timeIntervalSince1970: 1_750_000_000)

    // Chat cannot import app-target applets, so this rail fixture uses ChatsApplet only.
    private static let sampleApplets: [any MiniApplet] = {
        // Fail fixture setup immediately if the in-memory database cannot open.
        // swiftlint:disable:next force_try
        let db = try! ChatDatabase.makeInMemory()
        return [ChatsApplet(chatDatabase: db)]
    }()

    private static let sampleChats: [SidebarViewModel.ChatItem] = [
        .init(id: "c1", title: "Italy trip planning", updatedAt: now, running: false),
        .init(id: "c2", title: "Pizza dough timing", updatedAt: now.addingTimeInterval(-300), running: false),
        .init(id: "c3", title: "Quarterly review notes", updatedAt: now.addingTimeInterval(-3_600), running: false),
        .init(id: "c4", title: "An overly long conversation title that must ellipsis", updatedAt: now.addingTimeInterval(-7_200), running: false),
    ]

    @Test("open empty in light")
    func openEmptyLight() {
        verify(theme: .vellumLight, chats: [], activeId: nil, name: "sidebar_open_empty_light")
    }

    @Test("open populated in light")
    func openPopulatedLight() {
        verify(theme: .vellumLight, chats: Self.sampleChats, activeId: "c1", name: "sidebar_open_populated_light")
    }

    @Test("open populated in dark")
    func openPopulatedDark() {
        verify(theme: .vellumDark, chats: Self.sampleChats, activeId: "c1", name: "sidebar_open_populated_dark")
    }

    @Test("active row highlighted in dark")
    func activeRowHighlightedDark() {
        verify(theme: .vellumDark, chats: Self.sampleChats, activeId: "c2", name: "sidebar_active_dark")
    }

    @Test("running spinner shows on streaming row")
    func runningSpinner() {
        var chats = Self.sampleChats
        chats[1] = .init(id: "c2", title: chats[1].title, updatedAt: chats[1].updatedAt, running: true)
        verify(theme: .vellumLight, chats: chats, activeId: "c1", name: "sidebar_running_light")
    }

    @Test("with overflow shows 'See all chats…' row")
    func seeAllOverflowRow() {
        let function = #function
        let viewModel = SidebarViewModel(
            conversationRepository: NoopConversationRepository(),
            sessionStore: makeIsolatedStore()
        )
        viewModel._setSnapshotState(
            chats: Self.sampleChats,
            activeId: "c1",
            hasMoreChats: true
        )
        let view = SidebarDrawer(
            isPresented: .constant(true),
            viewModel: viewModel,
            appInfo: appInfo,
            applets: Self.sampleApplets,
            activeAppletID: nil,
            onSelectConversation: { _ in },
            onNewChat: {},
            onOpenSettings: {},
            onSelectApplet: { _ in },
            onSeeAllChats: {}
        )
        .superTheme(.make(.vellumLight))
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: "sidebar_see_all_row_light", function: function)
    }

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
            applets: Self.sampleApplets,
            activeAppletID: nil,
            onSelectConversation: { _ in },
            onNewChat: {},
            onOpenSettings: {},
            onSelectApplet: { _ in },
            onSeeAllChats: {}
        )
        .superTheme(.make(.vellumLight))
        .dynamicTypeSize(.xxLarge)
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: "sidebar_open_populated_light_xxl", function: function)
    }

    @Test("font scale max — drawer scales with slider")
    func fontScaleMaxRowsScale() {
        verifyFontScaleMax(theme: .vellumLight, name: "sidebar_font_scale_max_light")
    }

    @Test("font scale max — drawer scales with slider (dark)")
    func fontScaleMaxRowsScaleDark() {
        verifyFontScaleMax(theme: .vellumDark, name: "sidebar_font_scale_max_dark")
    }

    private func verifyFontScaleMax(
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let viewModel = SidebarViewModel(
            conversationRepository: NoopConversationRepository(),
            sessionStore: makeIsolatedStore()
        )
        viewModel._setSnapshotState(chats: Self.sampleChats, activeId: "c1")
        let view = SidebarDrawer(
            isPresented: .constant(true),
            viewModel: viewModel,
            appInfo: appInfo,
            applets: Self.sampleApplets,
            activeAppletID: nil,
            onSelectConversation: { _ in },
            onNewChat: {},
            onOpenSettings: {},
            onSelectApplet: { _ in },
            onSeeAllChats: {}
        )
        .superTheme(.make(theme))
        .chatAppearance(ChatAppearance(fontScale: 1.20))
        .superTypography(.make(.serif, fontScale: 1.20))
        .frame(width: Self.frame.width, height: Self.frame.height)
        recordOrCompare(view: view, name: name, function: function)
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
            applets: Self.sampleApplets,
            activeAppletID: nil,
            onSelectConversation: { _ in },
            onNewChat: {},
            onOpenSettings: {},
            onSelectApplet: { _ in },
            onSeeAllChats: {}
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
        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: Self.frame.width, height: Self.frame.height)),
            named: name,
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
    func listActiveRecent(limit: Int) async throws -> [ConversationRecord] { [] }
    func fetch(id: String) async throws -> ConversationRecord? { nil }
    func save(_ record: ConversationRecord) async throws {}
    func softDelete(id: String, at deletedAt: Date) async throws {}
    func hardDelete(id: String) async throws {}
}

private actor NoopMessageRepository: MessageRepository {
    func fetchAll(conversationId: String) async throws -> [MessageRecord] { [] }
    func fetch(id: String) async throws -> MessageRecord? { nil }
    func hasUserMessage(conversationId: String) async throws -> Bool { false }
    func save(_ record: MessageRecord) async throws {}
    func delete(ids: [String]) async throws {}
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
    func delete(ids: [String]) async throws {}
}

private actor NoopEnablementRepository: ToolEnablementRepository {
    func isEnabled(toolID: String) async throws -> Bool? { nil }
    func setEnabled(toolID: String, enabled: Bool) async throws {}
    func allEnabled() async throws -> [String: Bool] { [:] }
}
#endif
