import Core
import Foundation

/// App-level coordinator that owns one `ChatSession` per conversation.
/// The store is a singleton in production; tests construct it directly.
///
/// Multiple sessions stream in parallel without sharing state — cancelling
/// one session never affects siblings, and a session's lifecycle outlives
/// the view model that started it (so switching away from a streaming chat
/// doesn't drop the response).
public actor ChatSessionStore {
    private let messageRepository: any MessageRepository
    private let toolCallRepository: any ToolCallRepository
    private let llmProviderRegistry: LLMProviderRegistry
    private let toolRegistry: ToolRegistry
    private let clock: any Clock
    private let idGenerator: any IDGenerator

    private var sessions: [String: ChatSession] = [:]

    public init(
        messageRepository: any MessageRepository,
        toolCallRepository: any ToolCallRepository,
        llmProviderRegistry: LLMProviderRegistry,
        toolRegistry: ToolRegistry,
        clock: any Clock = SystemClock(),
        idGenerator: any IDGenerator = UUIDGenerator()
    ) {
        self.messageRepository = messageRepository
        self.toolCallRepository = toolCallRepository
        self.llmProviderRegistry = llmProviderRegistry
        self.toolRegistry = toolRegistry
        self.clock = clock
        self.idGenerator = idGenerator
    }

    /// Get-or-create the session for a conversation. Subsequent calls with
    /// the same id return the same instance, so a streaming turn started
    /// in one view re-attaches when the view re-mounts.
    public func session(for conversationId: String) -> ChatSession {
        if let existing = sessions[conversationId] { return existing }
        let session = ChatSession(
            conversationId: conversationId,
            messageRepository: messageRepository,
            toolCallRepository: toolCallRepository,
            llmProviderRegistry: llmProviderRegistry,
            toolRegistry: toolRegistry,
            clock: clock,
            idGenerator: idGenerator
        )
        sessions[conversationId] = session
        return session
    }

    /// Cancel the session's current turn, if any. The session itself stays
    /// in the store so a subsequent `session(for:)` returns the same
    /// instance. Returns immediately; pass `wait: true` to await the
    /// session's wind-down (mirrors `ChatSession.cancel()` +
    /// `waitUntilFinished()`).
    public func cancel(for conversationId: String, wait: Bool = false) async {
        guard let session = sessions[conversationId] else { return }
        await session.cancel()
        if wait {
            await session.waitUntilFinished()
        }
    }

    /// Cancel every session, await each one's wind-down, and drop them.
    /// Call on app shutdown so in-flight GRDB writes settle before the
    /// process exits (otherwise SQLite has to recover on next launch).
    public func shutdown() async {
        let snapshot = sessions
        for (_, session) in snapshot {
            await session.cancel()
        }
        for (_, session) in snapshot {
            await session.waitUntilFinished()
        }
        sessions.removeAll()
    }

    /// Identifiers of conversations whose session currently has an in-flight turn.
    /// The sidebar reads this for the per-row running spinner. Polls each
    /// session in parallel via `withTaskGroup` so a 50-conversation store
    /// doesn't pay 50 serial actor hops per refresh.
    public func runningConversations() async -> [String] {
        let snapshot = sessions
        return await withTaskGroup(of: (String, Bool).self) { group in
            for (id, session) in snapshot {
                group.addTask {
                    let active = await session.isStreaming
                    return (id, active)
                }
            }
            var running: [String] = []
            for await (id, active) in group where active {
                running.append(id)
            }
            return running.sorted()
        }
    }
}
