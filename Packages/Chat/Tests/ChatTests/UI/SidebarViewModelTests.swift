import Core
import Foundation
import Testing
@testable import Chat

/// Tests for `SidebarViewModel.refresh()` — list ordering, running set
/// projection, and graceful repository-error fallback.
@Suite("SidebarViewModel")
@MainActor
struct SidebarViewModelTests {
    private static let now = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("refresh sorts conversations by updatedAt desc")
    func refreshSortsByUpdatedAt() async {
        let store = makeStore(running: [])
        let repo = StubConversationRepository(rows: [
            .init(id: "old", title: "Old chat", createdAt: Self.now.addingTimeInterval(-86400), updatedAt: Self.now.addingTimeInterval(-3600)),
            .init(id: "new", title: "New chat", createdAt: Self.now, updatedAt: Self.now),
            .init(id: "mid", title: "Middle chat", createdAt: Self.now.addingTimeInterval(-7200), updatedAt: Self.now.addingTimeInterval(-1800)),
        ])
        let vm = SidebarViewModel(conversationRepository: repo, sessionStore: store)
        await vm.refresh()
        #expect(vm.chats.map(\.id) == ["new", "mid", "old"])
    }

    @Test("nil and empty titles fall back to 'New chat'")
    func emptyTitleFallback() async {
        let store = makeStore(running: [])
        let repo = StubConversationRepository(rows: [
            .init(id: "a", title: nil, createdAt: Self.now, updatedAt: Self.now),
            .init(id: "b", title: "", createdAt: Self.now.addingTimeInterval(-1), updatedAt: Self.now.addingTimeInterval(-1)),
            .init(id: "c", title: "Real one", createdAt: Self.now.addingTimeInterval(-2), updatedAt: Self.now.addingTimeInterval(-2)),
        ])
        let vm = SidebarViewModel(conversationRepository: repo, sessionStore: store)
        await vm.refresh()
        #expect(vm.chats[0].title == "New chat")
        #expect(vm.chats[1].title == "New chat")
        #expect(vm.chats[2].title == "Real one")
    }

    @Test("repository error preserves prior chats list")
    func repositoryErrorPreservesPrior() async {
        let store = makeStore(running: [])
        let repo = StubConversationRepository(rows: [
            .init(id: "a", title: "A", createdAt: Self.now, updatedAt: Self.now),
        ])
        let vm = SidebarViewModel(conversationRepository: repo, sessionStore: store)
        await vm.refresh()
        #expect(vm.chats.count == 1)

        repo.shouldThrow = true
        await vm.refresh()
        #expect(vm.chats.count == 1) // unchanged
    }

    @Test("running ids surface as ChatItem.running flag")
    func runningFlagProjection() async {
        let repo = StubConversationRepository(rows: [
            .init(id: "a", title: "A", createdAt: Self.now, updatedAt: Self.now),
            .init(id: "b", title: "B", createdAt: Self.now.addingTimeInterval(-1), updatedAt: Self.now.addingTimeInterval(-1)),
        ])
        let vm = SidebarViewModel(
            conversationRepository: repo,
            runningSource: { ["b"] }
        )
        await vm.refresh()
        let running = Dictionary(uniqueKeysWithValues: vm.chats.map { ($0.id, $0.running) })
        #expect(running["a"] == false)
        #expect(running["b"] == true)
    }

    @Test("activeConversationId starts at the seeded value and is mutable")
    func activeConversationIdMutable() async {
        let store = makeStore(running: [])
        let repo = StubConversationRepository(rows: [])
        let vm = SidebarViewModel(
            conversationRepository: repo,
            sessionStore: store,
            activeConversationId: "seed"
        )
        #expect(vm.activeConversationId == "seed")
        vm.activeConversationId = "changed"
        #expect(vm.activeConversationId == "changed")
    }

    private func makeStore(running: [String]) -> ChatSessionStore {
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
        // Note: we don't have a way to seed the running set without
        // actually starting sessions. The pure projection that
        // `runningConversations()` returns is read by `refresh()`, and
        // `runningConversations()` returns []` for an empty store. This
        // lets the "running flag projection" test exercise the shape via
        // the dedicated test seam below.
    }
}

// MARK: - Test doubles

private final class StubConversationRepository: ConversationRepository, @unchecked Sendable {
    var rows: [ConversationRecord]
    var shouldThrow: Bool = false

    init(rows: [ConversationRecord]) {
        self.rows = rows
    }

    func listActive() async throws -> [ConversationRecord] {
        if shouldThrow { throw NSError(domain: "test", code: 1) }
        return rows.filter { $0.deletedAt == nil }
    }

    func fetch(id: String) async throws -> ConversationRecord? {
        rows.first { $0.id == id }
    }

    func save(_ record: ConversationRecord) async throws {
        rows.removeAll { $0.id == record.id }
        rows.append(record)
    }

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
