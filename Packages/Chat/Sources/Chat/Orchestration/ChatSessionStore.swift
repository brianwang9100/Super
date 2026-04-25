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
    /// instance.
    public func cancel(for conversationId: String) async {
        await sessions[conversationId]?.cancel()
    }

    /// Cancel every session and drop them. Call on app shutdown.
    public func shutdown() async {
        for (_, session) in sessions {
            await session.cancel()
        }
        sessions.removeAll()
    }

    /// IDs (Identifiers) of conversations whose session currently has an
    /// in-flight turn. The sidebar uses this to render the per-row running
    /// spinner.
    public func runningConversations() async -> [String] {
        var running: [String] = []
        for (id, session) in sessions where await session.isStreaming {
            running.append(id)
        }
        return running.sorted()
    }
}
