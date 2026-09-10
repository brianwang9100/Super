import Core
import Foundation
import Testing

@testable import Chat

@Suite("Session switching integration")
@MainActor
struct SessionSwitchingIntegrationTests {

    @Test("Switching view models mid-turn keeps the session running; VM2 re-attaches and sees completion")
    func swapMidTurnReAttachesAndCompletes() async throws {
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
        await provider.enqueue([
            .messageStart(id: "m1", model: model.id),
            .toolUse(index: 0, id: "tc-1", name: toolID, input: .object([:]), signature: nil),
            .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 0)),
        ])
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

        // Pause between the first assistant save and second round to swap view models mid-turn.
        await resumable.awaitFirstCall()

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

        #expect(vm2.isStreaming == true)
        #expect(vm2.streamingTail != nil)

        await resumable.resume(with: ToolResult(toolID: toolID, content: "{}", isError: false))

        await vm2._waitForPendingStreamTask()
        await session.waitUntilFinished()

        #expect(vm2.isStreaming == false)
        #expect(vm2.streamingTail == nil)
        let lastAssistantContent: String? = vm2.items.reversed().compactMap { item -> String? in
            if case .assistantText(_, _, _, let text, _, _, _, _, _) = item, !text.isEmpty {
                return text
            }
            return nil
        }.first
        #expect(lastAssistantContent == "all done")

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
