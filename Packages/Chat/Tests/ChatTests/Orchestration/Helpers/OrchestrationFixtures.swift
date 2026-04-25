import Core
import Foundation
import os

@testable import Chat

/// A `Clock` that advances by a fixed step on every `now()` call so back-
/// to-back writes inside one turn get strictly-increasing `createdAt`
/// timestamps. The `MessageRepository.fetchAll` query orders by `createdAt`
/// ascending; with a true `FixedClock` the ordering of tied rows is
/// undefined and history assembly can shuffle.
final class MonotonicClock: Clock {
    private let state: OSAllocatedUnfairLock<Date>
    private let step: TimeInterval

    init(start: Date = Date(timeIntervalSince1970: 1_700_000_000), step: TimeInterval = 0.001) {
        self.state = OSAllocatedUnfairLock(initialState: start)
        self.step = step
    }

    func now() -> Date {
        state.withLock { current in
            let result = current
            current = current.addingTimeInterval(step)
            return result
        }
    }

    func snapshot() -> Date { state.withLock { $0 } }
}

/// Factories shared by the orchestration test suites: an in-memory GRDB
/// stack, a freshly-seeded conversation, and a default `LLMModel`.
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
}
