import Core
import Foundation

@testable import Chat

// FixedClock deliberately creates timestamp ties to exercise repository rowid ordering.
enum OrchestrationFixtures {
    static func makeDatabase() throws -> ChatDatabase {
        try ChatDatabase.makeInMemory()
    }

    static func defaultModel(supportsTools: Bool = true) -> LLMModel {
        LLMModel(
            id: "fake-model-1",
            displayName: "Fake Model",
            supportsThinking: false,
            supportsTools: supportsTools,
            maxContextTokens: 8_192
        )
    }

    static func defaultClock() -> FixedClock {
        FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
    }

    static func makeConversation(
        id: String = "conv-1",
        title: String? = "Test conversation",
        clock: any Clock
    ) -> ConversationRecord {
        let now = clock.now()
        return ConversationRecord(
            id: id,
            title: title,
            createdAt: now,
            updatedAt: now,
            deletedAt: nil
        )
    }

    static func seedConversation(
        in database: ChatDatabase,
        id: String = "conv-1",
        clock: any Clock
    ) async throws -> ConversationRecord {
        let conversation = makeConversation(id: id, clock: clock)
        try await database.queue.write { db in
            try conversation.insert(db)
        }
        return conversation
    }

    static func makeCompactor(
        database: ChatDatabase,
        llmRegistry: LLMProviderRegistry,
        clock: any Clock,
        idGenerator: any IDGenerator
    ) -> Compactor {
        let checkpointRepo = GRDBCompactionCheckpointRepository(database: database)
        return Compactor(
            llmProviderRegistry: llmRegistry,
            checkpointRepository: checkpointRepo,
            clock: clock,
            idGenerator: idGenerator
        )
    }
}
