import Core

extension ChatSession {
    /// Owns an isolated in-memory transcript for as long as the session is retained.
    /// The provider is pinned for this session; no application Chat history is written.
    public static func makeEphemeral(
        provider: any LLMProvider,
        toolRegistry: ToolRegistry,
        briefing: String,
        configuration: ChatSessionConfiguration = .init(),
        clock: any Clock = SystemClock(),
        idGenerator: any IDGenerator = UUIDGenerator()
    ) async throws -> ChatSession {
        try Task.checkCancellation()
        let providers = LLMProviderRegistry()
        await providers.register(provider)
        let database = try ChatDatabase.makeInMemory()
        let conversations = GRDBConversationRepository(database: database)
        let checkpoints = GRDBCompactionCheckpointRepository(database: database)
        let conversation = ConversationRecord(
            id: idGenerator.nextID(), kind: .transient,
            createdAt: clock.now(), updatedAt: clock.now()
        )
        try await conversations.save(conversation)
        return ChatSession(
            conversationId: conversation.id,
            messageRepository: GRDBMessageRepository(database: database),
            toolCallRepository: GRDBToolCallRepository(database: database),
            checkpointRepository: checkpoints,
            llmProviderRegistry: providers,
            toolRegistry: toolRegistry,
            compactor: Compactor(
                llmProviderRegistry: providers, checkpointRepository: checkpoints,
                clock: clock, idGenerator: idGenerator
            ),
            clock: clock,
            idGenerator: idGenerator,
            chatBriefing: briefing,
            configuration: configuration
        )
    }
}
