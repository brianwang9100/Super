import Core
import Foundation
import SwiftUI

/// View model for `SidebarDrawer`. Owns the conversation list (sourced
/// from `ConversationRepository`) and the set of conversations currently
/// streaming (sourced from `ChatSessionStore.runningConversations()`).
///
/// Refreshes only when the host calls `refresh()` — currently that's just
/// "when the drawer opens." There is no live `ValueObservation` yet, so
/// changes that happen while the drawer stays open (a streaming chat
/// finishing, a new chat being persisted from elsewhere) won't surface
/// until the next open. The timer / observation upgrade is queued for
/// M9 alongside Settings, when GRDBQuery threading lands.
@MainActor
@Observable
public final class SidebarViewModel {
    /// One row in the CHATS list. Mirrors the React `ChatRow` payload.
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

    /// Conversations sorted newest-first. Re-projected on each
    /// `refresh()` (and whenever `draftConversation` changes); stale
    /// otherwise.
    public private(set) var chats: [ChatItem] = []

    /// `true` when there are more than 10 active conversations on disk.
    /// The drawer reads this to decide whether to render the "See all
    /// chats…" footer that switches the backdrop to the Chats applet.
    /// Set inside `refresh()` from the repository's overage-by-one probe.
    public private(set) var hasMoreChats: Bool = false

    /// Hard cap on the number of rows the sidebar surfaces. Anything
    /// beyond is reachable through the Chats applet's full list.
    public static let sidebarChatLimit: Int = 10

    /// The conversation currently shown in the chat surface. Setting this
    /// repaints the matching row in `accentSoft + accent ink` — it does
    /// not by itself swap the chat surface; the host owns that.
    public var activeConversationId: String?

    /// In-memory "New Chat" record that hasn't been persisted yet. The
    /// host sets this when the user taps New Chat (or first launches
    /// into an empty DB) so the sidebar can show the draft as a normal
    /// row (highlighted as active) up until the user sends the first
    /// message — at which point persistence lands and the next
    /// `refresh()` self-clears this pointer because the conversation
    /// now appears in the DB-backed list.
    public var draftConversation: ConversationRecord? {
        didSet { rebuildChats() }
    }

    private let conversationRepository: any ConversationRepository
    private let runningSource: @Sendable () async -> [String]
    /// DB-backed projection from the most recent `refresh()`. Kept
    /// separate so `rebuildChats()` can prepend the draft row without
    /// re-querying.
    private var dbChats: [ChatItem] = []

    /// Production initializer — bridges to the live `ChatSessionStore`'s
    /// `runningConversations()` actor method.
    public init(
        conversationRepository: any ConversationRepository,
        sessionStore: ChatSessionStore,
        activeConversationId: String? = nil
    ) {
        self.conversationRepository = conversationRepository
        self.runningSource = { [sessionStore] in await sessionStore.runningConversations() }
        self.activeConversationId = activeConversationId
    }

    /// Test-friendly initializer that lets the running set be driven by a
    /// closure. Production callers go through the `sessionStore` overload;
    /// see `SidebarViewModelTests` for usage.
    public init(
        conversationRepository: any ConversationRepository,
        runningSource: @escaping @Sendable () async -> [String],
        activeConversationId: String? = nil
    ) {
        self.conversationRepository = conversationRepository
        self.runningSource = runningSource
        self.activeConversationId = activeConversationId
    }

    /// Re-read the conversation list (capped at the sidebar limit, plus
    /// one probe row for overflow detection) and the running set, then
    /// project into `chats`. Swallows repository errors and leaves the
    /// list in its prior state — surfacing a sidebar-level error UI is
    /// M12 polish.
    public func refresh() async {
        let conversations: [ConversationRecord]
        do {
            // Ask for one more than the visible cap. A `limit + 1` row
            // count means "there's more on disk" → the drawer renders
            // its "See all chats…" footer routing to the Chats applet.
            conversations = try await conversationRepository.listActiveRecent(
                limit: Self.sidebarChatLimit + 1
            )
        } catch {
            return
        }
        let running = Set(await runningSource())
        // `listActiveRecent` already returns rows in `updatedAt DESC`
        // order (the repository's `.order(.desc)` clause is the single
        // source of truth). No client-side re-sort here — same order
        // falls out either way.
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
        // If the DB now contains the draft, the persistence step landed
        // and we drop the in-memory pointer (the regular row will be
        // rendered instead). Otherwise just re-merge.
        if let draft = draftConversation,
           dbChats.contains(where: { $0.id == draft.id }) {
            // didSet on draftConversation also calls rebuildChats().
            draftConversation = nil
        } else {
            rebuildChats()
        }
    }

    /// Re-merge `dbChats` with the optional draft into `chats`. Drafts
    /// always sit at the top so the user sees their just-tapped New
    /// Chat regardless of how recent the persisted rows are.
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

    /// Pre-populate `chats` synchronously for snapshot tests + previews so
    /// the view renders without a repository round-trip. Production
    /// callers should never invoke this — `refresh()` is the canonical
    /// entry point.
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
