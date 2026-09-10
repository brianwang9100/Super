import Core
import Foundation
import SwiftUI

/// Host-driven refresh; draft changes merge locally without querying persistence.
@MainActor
@Observable
public final class SidebarViewModel {
    public struct ChatItem: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let updatedAt: Date
        public let running: Bool

        public init(id: String, title: String, updatedAt: Date, running: Bool) {
            self.id = id
            self.title = title
            self.updatedAt = updatedAt
            self.running = running
        }
    }

    public private(set) var chats: [ChatItem] = []

    public private(set) var hasMoreChats: Bool = false

    public static let sidebarChatLimit: Int = 10

    public var activeConversationId: String?

    /// Show an unpersisted conversation until it appears in the refreshed database rows.
    public var draftConversation: ConversationRecord? {
        didSet { rebuildChats() }
    }

    private let conversationRepository: any ConversationRepository
    private let runningSource: @Sendable () async -> [String]
    private var dbChats: [ChatItem] = []

    public init(
        conversationRepository: any ConversationRepository,
        sessionStore: ChatSessionStore,
        activeConversationId: String? = nil
    ) {
        self.conversationRepository = conversationRepository
        self.runningSource = { [sessionStore] in await sessionStore.runningConversations() }
        self.activeConversationId = activeConversationId
    }

    public init(
        conversationRepository: any ConversationRepository,
        runningSource: @escaping @Sendable () async -> [String],
        activeConversationId: String? = nil
    ) {
        self.conversationRepository = conversationRepository
        self.runningSource = runningSource
        self.activeConversationId = activeConversationId
    }

    /// Preserve the previous list if the repository read fails.
    public func refresh() async {
        let conversations: [ConversationRecord]
        do {
            // Fetch one extra row to detect overflow beyond the visible cap.
            conversations = try await conversationRepository.listActiveRecent(
                limit: Self.sidebarChatLimit + 1
            )
        } catch {
            return
        }
        let running = Set(await runningSource())
        hasMoreChats = conversations.count > Self.sidebarChatLimit
        dbChats = conversations
            .prefix(Self.sidebarChatLimit)
            .map { record in
                let title: String
                if let raw = record.title, !raw.isEmpty {
                    title = raw
                } else {
                    title = "New chat"
                }
                return ChatItem(
                    id: record.id,
                    title: title,
                    updatedAt: record.updatedAt,
                    running: running.contains(record.id)
                )
            }
        if let draft = draftConversation,
           dbChats.contains(where: { $0.id == draft.id }) {
            draftConversation = nil
        } else {
            rebuildChats()
        }
    }

    private func rebuildChats() {
        var rows = dbChats
        if let draft = draftConversation,
           !rows.contains(where: { $0.id == draft.id }) {
            let title: String
            if let raw = draft.title, !raw.isEmpty {
                title = raw
            } else {
                title = "New chat"
            }
            rows.insert(
                ChatItem(
                    id: draft.id,
                    title: title,
                    updatedAt: draft.updatedAt,
                    running: false
                ),
                at: 0
            )
        }
        chats = rows
    }

    /// Seed a snapshot without querying repositories.
    func _setSnapshotState(
        chats: [ChatItem],
        activeId: String? = nil,
        hasMoreChats: Bool = false
    ) {
        self.chats = chats
        self.dbChats = chats
        self.activeConversationId = activeId
        self.hasMoreChats = hasMoreChats
    }
}
