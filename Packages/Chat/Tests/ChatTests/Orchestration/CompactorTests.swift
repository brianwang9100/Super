import Core
import Foundation
import Testing

@testable import Chat

/// Tests for `Compactor` — issues a summarization turn through a fake
/// `LLMProvider`, persists a `CompactionCheckpointRecord`, and demotes
/// any prior live one in the same write.
@Suite("Compactor")
struct CompactorTests {

    private struct Setup {
        let database: ChatDatabase
        let checkpointRepo: GRDBCompactionCheckpointRepository
        let llmRegistry: LLMProviderRegistry
        let provider: FakeLLMProvider
        let model: LLMModel
        let compactor: Compactor
        let conversation: ConversationRecord
        let clock: FixedClock
        let idGen: DeterministicIDGenerator
    }

    private func makeSetup(scripts: [[LLMStreamEvent]] = []) async throws -> Setup {
        let database = try ChatDatabase.makeInMemory()
        let checkpointRepo = GRDBCompactionCheckpointRepository(database: database)
        let clock = OrchestrationFixtures.defaultClock()
        let idGen = DeterministicIDGenerator(prefix: "ck-", start: 0)
        let model = OrchestrationFixtures.defaultModel()
        let provider = FakeLLMProvider(model: model)
        for script in scripts { await provider.enqueue(script) }
        let llmRegistry = LLMProviderRegistry()
        await llmRegistry.register(provider)
        let compactor = OrchestrationFixtures.makeCompactor(
            database: database,
            llmRegistry: llmRegistry,
            clock: clock,
            idGenerator: idGen
        )
        let conversation = try await OrchestrationFixtures.seedConversation(in: database, clock: clock)
        return Setup(
            database: database,
            checkpointRepo: checkpointRepo,
            llmRegistry: llmRegistry,
            provider: provider,
            model: model,
            compactor: compactor,
            conversation: conversation,
            clock: clock,
            idGen: idGen
        )
    }

    /// 10 user/assistant pairs — enough to leave plenty of summarizable
    /// history beyond the default `keepMostRecent = 4`.
    private func seedPlentyOfMessages(setup: Setup) async throws -> [MessageRecord] {
        let messageRepo = GRDBMessageRepository(database: setup.database)
        var rows: [MessageRecord] = []
        for index in 1...10 {
            let user = MessageRecord(
                id: "m-u\(index)",
                conversationId: setup.conversation.id,
                role: .user,
                content: "user message \(index)",
                createdAt: setup.clock.now()
            )
            try await messageRepo.save(user)
            rows.append(user)
            let assistant = MessageRecord(
                id: "m-a\(index)",
                conversationId: setup.conversation.id,
                role: .assistant,
                content: "assistant reply \(index)",
                createdAt: setup.clock.now()
            )
            try await messageRepo.save(assistant)
            rows.append(assistant)
        }
        return rows
    }

    @Test func compactPersistsNewLiveCheckpointWithCorrectFields() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "sum-1", model: "fake-model-1"),
                .textDelta(index: 0, text: "Summary: they exchanged 8 greetings."),
                .messageComplete(usage: TokenUsage(inputTokens: 50, outputTokens: 8)),
            ],
        ])
        let messages = try await seedPlentyOfMessages(setup: setup)

        let checkpoint = try await setup.compactor.compact(
            conversationId: setup.conversation.id,
            messages: messages,
            toolCalls: [],
            priorCheckpoint: nil,
            model: setup.model
        )

        #expect(checkpoint != nil)
        let saved = try #require(checkpoint)
        // The checkpoint covers everything except the last 4 messages
        // (default keepMostRecent). With 20 messages total, that's the
        // 16th in 1-indexed order — `m-a8`.
        #expect(saved.uptoMessageId == "m-a8")
        #expect(saved.summary.contains("Summary: they exchanged 8 greetings"))
        #expect(saved.isLive)
        #expect(saved.tokensBefore > saved.tokensAfter)

        // Also persisted: the live checkpoint readable back.
        let live = try await setup.checkpointRepo.liveCheckpoint(for: setup.conversation.id)
        #expect(live?.id == saved.id)
    }

    @Test func compactDemotesPriorLiveCheckpointInSameTransaction() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "sum-2", model: "fake-model-1"),
                .textDelta(index: 0, text: "Updated summary."),
                .messageComplete(usage: TokenUsage(inputTokens: 60, outputTokens: 4)),
            ],
        ])
        let messages = try await seedPlentyOfMessages(setup: setup)

        // Pre-existing live checkpoint covering an earlier window.
        let prior = CompactionCheckpointRecord(
            id: "ck-prior",
            conversationId: setup.conversation.id,
            uptoMessageId: "m-a4",
            summary: "Older summary.",
            tokensBefore: 80,
            tokensAfter: 8,
            createdAt: setup.clock.now(),
            isLive: true
        )
        try await setup.checkpointRepo.save(prior)

        _ = try await setup.compactor.compact(
            conversationId: setup.conversation.id,
            messages: messages,
            toolCalls: [],
            priorCheckpoint: prior,
            model: setup.model
        )

        let allCheckpoints = try await setup.checkpointRepo.all(for: setup.conversation.id)
        // Both rows present; only the new one is live.
        #expect(allCheckpoints.count == 2)
        let liveRows = allCheckpoints.filter(\.isLive)
        #expect(liveRows.count == 1)
        #expect(liveRows.first?.id != prior.id)
        let supersededPrior = allCheckpoints.first(where: { $0.id == prior.id })
        #expect(supersededPrior?.isLive == false)
    }

    @Test func compactReturnsNilWhenTooFewMessagesToSummarize() async throws {
        let setup = try await makeSetup(scripts: []) // No script needed — provider must not be called.
        let messageRepo = GRDBMessageRepository(database: setup.database)
        // Three messages — fewer than keepMostRecent + 1 (5).
        for index in 1...3 {
            let row = MessageRecord(
                id: "m\(index)",
                conversationId: setup.conversation.id,
                role: .user,
                content: "msg \(index)",
                createdAt: setup.clock.now()
            )
            try await messageRepo.save(row)
        }
        let messages = try await messageRepo.fetchAll(conversationId: setup.conversation.id)

        let checkpoint = try await setup.compactor.compact(
            conversationId: setup.conversation.id,
            messages: messages,
            toolCalls: [],
            priorCheckpoint: nil,
            model: setup.model
        )
        #expect(checkpoint == nil)
        // Provider was never called — no script was enqueued.
        let calls = await setup.provider.capturedRequests()
        #expect(calls.isEmpty)
    }

    @Test func emptySummaryFromProviderThrows() async throws {
        let setup = try await makeSetup(scripts: [
            [
                // Provider yields no text, just messageComplete.
                .messageStart(id: "sum-empty", model: "fake-model-1"),
                .messageComplete(usage: TokenUsage(inputTokens: 30, outputTokens: 0)),
            ],
        ])
        let messages = try await seedPlentyOfMessages(setup: setup)

        await #expect(throws: CompactorError.self) {
            _ = try await setup.compactor.compact(
                conversationId: setup.conversation.id,
                messages: messages,
                toolCalls: [],
                priorCheckpoint: nil,
                model: setup.model
            )
        }
    }

    @Test func providerErrorEventBubblesAsCompactorLLMError() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "sum-err", model: "fake-model-1"),
                .error(.unauthorized),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
        ])
        let messages = try await seedPlentyOfMessages(setup: setup)

        do {
            _ = try await setup.compactor.compact(
                conversationId: setup.conversation.id,
                messages: messages,
                toolCalls: [],
                priorCheckpoint: nil,
                model: setup.model
            )
            Issue.record("expected compact to throw, succeeded instead")
        } catch let error as CompactorError {
            switch error {
            case .llmError(let llmError):
                #expect(llmError == .unauthorized)
            default:
                Issue.record("expected .llmError, got \(error)")
            }
        } catch {
            Issue.record("expected CompactorError, got \(error)")
        }
    }

    @Test func stalePriorCheckpointFallsBackToFullHistory() async throws {
        // Regression: a `priorCheckpoint` whose `uptoMessageId` isn't in
        // the message list (deleted, restored from sync, etc.) used to
        // make the pre-flight no-op forever. Compactor falls back to
        // summarizing the full list — and `wouldCompact` must agree.
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "sum-stale", model: "fake-model-1"),
                .textDelta(index: 0, text: "Recovered summary."),
                .messageComplete(usage: TokenUsage(inputTokens: 30, outputTokens: 2)),
            ],
        ])
        let messages = try await seedPlentyOfMessages(setup: setup)
        let stale = CompactionCheckpointRecord(
            id: "ck-stale",
            conversationId: setup.conversation.id,
            uptoMessageId: "m-vanished",
            summary: "Lost summary.",
            tokensBefore: 40,
            tokensAfter: 4,
            createdAt: setup.clock.now(),
            isLive: true
        )

        // Predicate must agree with the full-fallback behavior.
        #expect(setup.compactor.wouldCompact(messages: messages, priorCheckpoint: stale))

        let checkpoint = try await setup.compactor.compact(
            conversationId: setup.conversation.id,
            messages: messages,
            toolCalls: [],
            priorCheckpoint: stale,
            model: setup.model
        )
        #expect(checkpoint != nil)
    }

    @Test func keepMostRecentBoundaryProducesExactlyOneSummarizedMessage() async throws {
        // Tight boundary: with `keepMostRecent = 2` and exactly 3 messages
        // (and no prior checkpoint), the compactor should produce a
        // checkpoint whose `uptoMessageId` is the very first message — a
        // single summarized row, with the trailing two kept verbatim.
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "sum-bound", model: "fake-model-1"),
                .textDelta(index: 0, text: "boundary summary"),
                .messageComplete(usage: TokenUsage(inputTokens: 5, outputTokens: 2)),
            ],
        ])
        let messageRepo = GRDBMessageRepository(database: setup.database)
        let rows = (1...3).map { index in
            MessageRecord(
                id: "b\(index)",
                conversationId: setup.conversation.id,
                role: .user,
                content: "msg \(index)",
                createdAt: setup.clock.now()
            )
        }
        for row in rows { try await messageRepo.save(row) }
        let messages = try await messageRepo.fetchAll(conversationId: setup.conversation.id)

        let checkpoint = try await setup.compactor.compact(
            conversationId: setup.conversation.id,
            messages: messages,
            toolCalls: [],
            priorCheckpoint: nil,
            model: setup.model,
            keepMostRecent: 2
        )
        let saved = try #require(checkpoint)
        #expect(saved.uptoMessageId == "b1")

        // Just below the boundary: 2 messages + keepMostRecent = 2 →
        // nothing to summarize.
        #expect(setup.compactor.wouldCompact(
            messages: Array(messages.prefix(2)),
            priorCheckpoint: nil,
            keepMostRecent: 2
        ) == false)
    }

    @Test func summarizationPromptCarriesPriorSummaryWhenPresent() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "sum-3", model: "fake-model-1"),
                .textDelta(index: 0, text: "Combined summary."),
                .messageComplete(usage: TokenUsage(inputTokens: 30, outputTokens: 2)),
            ],
        ])
        let messages = try await seedPlentyOfMessages(setup: setup)
        let prior = CompactionCheckpointRecord(
            id: "ck-prior",
            conversationId: setup.conversation.id,
            uptoMessageId: "m-a3",
            summary: "Previously: discussed travel plans.",
            tokensBefore: 70,
            tokensAfter: 7,
            createdAt: setup.clock.now(),
            isLive: true
        )
        try await setup.checkpointRepo.save(prior)

        _ = try await setup.compactor.compact(
            conversationId: setup.conversation.id,
            messages: messages,
            toolCalls: [],
            priorCheckpoint: prior,
            model: setup.model
        )

        let captured = await setup.provider.capturedRequests()
        let firstRequest = try #require(captured.first)
        // The summarization prompt should have a system message
        // containing the prior summary verbatim, so the new summary
        // subsumes it.
        let containsPrior = firstRequest.messages.contains { msg in
            guard msg.role == .system else { return false }
            if case .text(let text) = msg.content.first {
                return text.contains("Previously: discussed travel plans.")
            }
            return false
        }
        #expect(containsPrior)
    }
}
