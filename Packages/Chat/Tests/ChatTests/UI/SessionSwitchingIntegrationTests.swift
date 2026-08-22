import Core
import Foundation
import Testing

@testable import Chat

/// End-to-end coverage for the session-switching contract. Drives two
/// successive `ChatScreenViewModel` instances against a single real
/// `ChatSession` (via `LiveChatSessionDriver`) to prove the documented
/// behavior: switching away from a streaming chat does not abort the
/// turn, and switching back re-attaches via `subscribe()` so the new
/// view model sees the response complete.
@Suite("Session switching integration")
@MainActor
struct SessionSwitchingIntegrationTests {

    @Test("Switching view models mid-turn keeps the session running; VM2 re-attaches and sees completion")
    func swapMidTurnReAttachesAndCompletes() async throws {
        // Real GRDB stack, real ChatSession, fake LLM provider, resumable
        // tool. The tool is the synchronization point — it lets the test
        // pause the run loop deterministically so the VM swap happens
        // mid-turn.
        let database = try ChatDatabase.makeInMemory()
        let messageRepo = GRDBMessageRepository(database: database)
        let toolCallRepo = GRDBToolCallRepository(database: database)
        let checkpointRepo = GRDBCompactionCheckpointRepository(database: database)
        let conversationRepo = GRDBConversationRepository(database: database)
        let clock = OrchestrationFixtures.defaultClock()
        let idGen = DeterministicIDGenerator(prefix: "id-", start: 0)

        let conversation = try await OrchestrationFixtures.seedConversation(in: database, clock: clock)
        let model = OrchestrationFixtures.defaultModel()

        let toolID = "test.resumable"
        let toolDef = LLMTool(
            id: toolID,
            name: "resumable",
            description: "Test tool that waits for an external resume.",
            category: .query,
            parameters: [],
            appletId: "test"
        )
        let resumable = ResumableToolExecutor(toolID: toolID)

        let provider = FakeLLMProvider(model: model)
        // Round 1: emit a tool call so the run loop pauses inside
        // `executeToolCalls` once the tool actually starts.
        await provider.enqueue([
            .messageStart(id: "m1", model: model.id),
            .toolUse(index: 0, id: "tc-1", name: toolID, input: .object([:]), signature: nil),
            .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 0)),
        ])
        // Round 2: after the tool resumes, emit the final assistant text.
        await provider.enqueue([
            .messageStart(id: "m2", model: model.id),
            .textDelta(index: 0, text: "all done"),
            .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
        ])

        let llmRegistry = LLMProviderRegistry()
        await llmRegistry.register(provider)
        let toolRegistry = ToolRegistry()
        await toolRegistry.register(ToolRegistration(tool: toolDef, execution: .local(resumable)))
        let compactor = OrchestrationFixtures.makeCompactor(
            database: database,
            llmRegistry: llmRegistry,
            clock: clock,
            idGenerator: idGen
        )

        let session = ChatSession(
            conversationId: conversation.id,
            messageRepository: messageRepo,
            toolCallRepository: toolCallRepo,
            checkpointRepository: checkpointRepo,
            llmProviderRegistry: llmRegistry,
            toolRegistry: toolRegistry,
            compactor: compactor,
            clock: clock,
            idGenerator: idGen,
            autoCompactEnabled: false
        )
        let driver = LiveChatSessionDriver(session: session)

        let vm1 = makeViewModel(
            conversation: conversation,
            driver: driver,
            model: model,
            messageRepo: messageRepo,
            toolCallRepo: toolCallRepo,
            checkpointRepo: checkpointRepo,
            conversationRepo: conversationRepo
        )
        await vm1.load()
        vm1.send("kick")

        // Wait until the tool actually starts running. At this point the
        // run loop is parked inside `executeToolCalls` — the first
        // round's assistant message has already been persisted, and the
        // second round hasn't started yet.
        await resumable.awaitFirstCall()

        // The host's view-model swap: detach the outgoing VM (its
        // streamTask cancels and the subscriber drops from the session's
        // fan-out) and construct a fresh VM against the same session.
        vm1.detachFromLiveTurn()

        let vm2 = makeViewModel(
            conversation: conversation,
            driver: driver,
            model: model,
            messageRepo: messageRepo,
            toolCallRepo: toolCallRepo,
            checkpointRepo: checkpointRepo,
            conversationRepo: conversationRepo
        )
        await vm2.load()

        // VM2 attached to the live turn: its `load()` called
        // `subscribe()`, the snapshot was non-nil (turn in flight), and
        // it spawned an iteration task. `isStreaming` flipped on.
        #expect(vm2.isStreaming == true)
        #expect(vm2.streamingTail != nil)

        // Resume the tool — the second round emits `all done`, the
        // assistant row persists, and both subscribers' streams close.
        await resumable.resume(with: ToolResult(toolID: toolID, content: "{}", isError: false))

        // Deterministically wait for VM2's iteration task to drain.
        // `_waitForPendingStreamTask()` mirrors the `_waitForPending-
        // TitleTask()` pattern (see AGENTS.md "Make async tests
        // deterministic") — no polling, no race amplifiers.
        await vm2._waitForPendingStreamTask()
        await session.waitUntilFinished()

        // VM2 should display two assistant rows: round 1 (tool-only,
        // no text — but it still emits a row because of the tool call)
        // and round 2 with "all done". Verify the final visible state.
        #expect(vm2.isStreaming == false)
        #expect(vm2.streamingTail == nil)
        let lastAssistantContent: String? = vm2.items.reversed().compactMap { item -> String? in
            if case .assistantText(_, _, _, let text, _, _, _, _, _) = item, !text.isEmpty {
                return text
            }
            return nil
        }.first
        #expect(lastAssistantContent == "all done")

        // Final persisted state: two assistant rows + one tool result.
        let persisted = try await messageRepo.fetchAll(conversationId: conversation.id)
        let assistantRows = persisted.filter { $0.role == .assistant }
        #expect(assistantRows.count == 2)
        #expect(assistantRows.last?.content == "all done")
    }

    // MARK: - Helpers

    private func makeViewModel(
        conversation: ConversationRecord,
        driver: any ChatSessionDriver,
        model: LLMModel,
        messageRepo: any MessageRepository,
        toolCallRepo: any ToolCallRepository,
        checkpointRepo: any CompactionCheckpointRepository,
        conversationRepo: any ConversationRepository
    ) -> ChatScreenViewModel {
        ChatScreenViewModel(
            conversationId: conversation.id,
            conversationTitle: conversation.title ?? "Test",
            driver: driver,
            messageRepository: messageRepo,
            toolCallRepository: toolCallRepo,
            checkpointRepository: checkpointRepo,
            availableModels: [SelectableModel(model)],
            selectedModelId: model.id,
            conversationRepository: conversationRepo
        )
    }

}
