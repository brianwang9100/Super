import Core
import Foundation
import Synchronization
import Testing
@testable import Chat

@Suite("ChatScreenViewModel")
@MainActor
struct ChatScreenViewModelTests {
    private let conversationId = "conv-1"
    private let model = LLMModel(
        id: "test-model",
        displayName: "Test",
        supportsThinking: false,
        supportsTools: true,
        maxContextTokens: 1000
    )

    private func makeModel(id: String) -> LLMModel {
        LLMModel(
            id: id,
            displayName: id,
            supportsThinking: false,
            supportsTools: true,
            maxContextTokens: 1000
        )
    }

    private func makeTitleGenerator(registry: LLMProviderRegistry) async -> TitleGenerator {
        let store = ChatSettingsStore(repository: TitleSettingRepository())
        try? await store.setSummarizeTitlesEnabled(true)
        try? await store.setTitleModelId(model.id)
        return TitleGenerator(llmProviderRegistry: registry, settingsStore: store)
    }

    @Test("resolveInitialModelId returns the persisted record id when it is in the available list")
    func resolveInitialModelIdReturnsPersistedWhenValid() {
        let a = SelectableModel(recordId: "rec-a", model: makeModel(id: "model-a"))
        let b = SelectableModel(recordId: "rec-b", model: makeModel(id: "model-b"))
        let resolved = ChatScreenViewModel.resolveInitialModelId(
            persisted: "rec-b",
            available: [a, b]
        )
        #expect(resolved == "rec-b")
    }

    @Test("resolveInitialModelId maps a legacy persisted model id to its record id")
    func resolveInitialModelIdMapsLegacyModelId() {
        // Legacy preferences store model IDs; resolve to a record ID for the next save.
        let a = SelectableModel(recordId: "rec-a", model: makeModel(id: "model-a"))
        let b = SelectableModel(recordId: "rec-b", model: makeModel(id: "model-b"))
        let resolved = ChatScreenViewModel.resolveInitialModelId(
            persisted: "model-b",
            available: [a, b]
        )
        #expect(resolved == "rec-b")
    }

    @Test("resolveInitialModelId falls back to first available when persisted is nil")
    func resolveInitialModelIdFallsBackWhenNilPersisted() {
        let a = SelectableModel(recordId: "rec-a", model: makeModel(id: "model-a"))
        let b = SelectableModel(recordId: "rec-b", model: makeModel(id: "model-b"))
        let resolved = ChatScreenViewModel.resolveInitialModelId(
            persisted: nil,
            available: [a, b]
        )
        #expect(resolved == "rec-a")
    }

    @Test("resolveInitialModelId falls back to first available when persisted id is stale")
    func resolveInitialModelIdFallsBackWhenStalePersisted() {
        let a = SelectableModel(recordId: "rec-a", model: makeModel(id: "model-a"))
        let b = SelectableModel(recordId: "rec-b", model: makeModel(id: "model-b"))
        let resolved = ChatScreenViewModel.resolveInitialModelId(
            persisted: "deleted-model",
            available: [a, b]
        )
        #expect(resolved == "rec-a")
    }

    @Test("resolveInitialModelId returns nil when no models are available")
    func resolveInitialModelIdReturnsNilWhenEmpty() {
        let resolved = ChatScreenViewModel.resolveInitialModelId(
            persisted: "any-id",
            available: []
        )
        #expect(resolved == nil)
    }

    @Test("two rows sharing a modelId are independently selectable by record id")
    func sameModelIdRowsSelectableByRecordId() {
        let shared = "gpt-4o"
        let a = SelectableModel(recordId: "rec-a", model: makeModel(id: shared))
        let b = SelectableModel(recordId: "rec-b", model: makeModel(id: shared))
        let vm = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: ScriptedDriver(events: []),
            messageRepository: StubMessageRepository(initial: []),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [a, b],
            selectedModelId: "rec-b"
        )
        #expect(vm.activeModel?.id == shared)
        vm.selectedModelId = "rec-a"
        #expect(vm.selectedModelId == "rec-a")
        #expect(vm.activeModel?.id == shared)
    }

    // MARK: - Empty-state suggestions

    @Test("loadSuggestionsIfNeeded resolves the provider's suggestions into state")
    func loadsGeneratedSuggestions() async {
        let scripted = [SuggestedChatAction(label: "Read a psalm", message: "Read a psalm")]
        let vm = makeEmptyViewModel(suggestionsProvider: FakeChatSuggestionsProvider(scripted: scripted))
        vm.loadSuggestionsIfNeeded(fallback: [SuggestedChatAction(label: "FB", message: "FB")])
        await vm._waitForPendingSuggestionsTask()
        #expect(vm.suggestions == scripted)
    }

    @Test("loadSuggestionsIfNeeded is idempotent — the second call is a no-op")
    func loadSuggestionsIsIdempotent() async {
        let vm = makeEmptyViewModel(suggestionsProvider: StaticChatSuggestionsProvider())
        vm.loadSuggestionsIfNeeded(fallback: [SuggestedChatAction(label: "first", message: "first")])
        await vm._waitForPendingSuggestionsTask()
        vm.loadSuggestionsIfNeeded(fallback: [SuggestedChatAction(label: "second", message: "second")])
        await vm._waitForPendingSuggestionsTask()
        #expect(vm.suggestions.map(\.label) == ["first"])
    }

    @Test("the static provider yields the fallback suggestions verbatim")
    func staticProviderYieldsFallback() async {
        let fb = [SuggestedChatAction(label: "FB", message: "FB")]
        let vm = makeEmptyViewModel(suggestionsProvider: StaticChatSuggestionsProvider())
        vm.loadSuggestionsIfNeeded(fallback: fb)
        await vm._waitForPendingSuggestionsTask()
        #expect(vm.suggestions == fb)
    }

    @Test("suggestions are not surfaced once the conversation has messages")
    func noSuggestionsWhenNotEmpty() async {
        let vm = makeEmptyViewModel(suggestionsProvider: StaticChatSuggestionsProvider())
        let msg = MessageRecord(id: "u1", conversationId: conversationId, role: .user, content: "hi", createdAt: Date(timeIntervalSince1970: 0))
        vm._setSnapshotState(items: ChatScreenViewModel.project(messages: [msg], toolCalls: [], checkpoint: nil))
        vm.loadSuggestionsIfNeeded(fallback: [SuggestedChatAction(label: "FB", message: "FB")])
        await vm._waitForPendingSuggestionsTask()
        #expect(vm.suggestions.isEmpty)
    }

    private func makeEmptyViewModel(
        suggestionsProvider: any ChatSuggestionsProvider
    ) -> ChatScreenViewModel {
        ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: ScriptedDriver(events: []),
            messageRepository: StubMessageRepository(initial: []),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [],
            suggestionsProvider: suggestionsProvider
        )
    }

    @Test("saved response stays live while its replacement loads")
    func responseHandoffKeepsTailUntilProjection() async {
        let user = MessageRecord(id: "u1", conversationId: conversationId, role: .user, content: "Question", createdAt: Date())
        let answer = MessageRecord(id: "a1", conversationId: conversationId, role: .assistant, content: "Visible response. ", createdAt: Date())
        let messages = StubMessageRepository(initial: [user, answer])
        await messages.suspendNextFetch()
        let vm = ChatScreenViewModel(
            conversationId: conversationId, conversationTitle: "Test",
            driver: ScriptedDriver(events: [.textDelta(answer.content), .assistantMessageSaved(answer)]),
            messageRepository: messages, toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(), availableModels: [SelectableModel(model)]
        )
        vm._setSnapshotState(items: [.userBubble(id: "u1", text: "Question", references: [])])
        vm.send("Question")
        await messages.waitForSuspendedFetch()
        #expect(vm.streamingTail?.text == answer.content)
        #expect(vm.items.map(\.id) == ["u1"])
        await messages.resumeFetch()
        await vm._waitForPendingStreamTask()
        #expect(vm.items.map(\.id) == ["u1", "a1"])
        #expect(vm.streamingTail == nil)
        #expect(vm.interruptedResponse == nil)
    }

    @Test("failed assistant reload still hands off before the next response round")
    func failedAssistantReloadDoesNotDuplicateTail() async {
        let user = MessageRecord(id: "u1", conversationId: conversationId, role: .user, content: "Question", createdAt: Date())
        let answer = MessageRecord(id: "a1", conversationId: conversationId, role: .assistant, content: "Saved response. ", createdAt: Date())
        let messages = StubMessageRepository(initial: [user, answer])
        await messages.failNextFetch()
        let vm = ChatScreenViewModel(
            conversationId: conversationId, conversationTitle: "Test",
            driver: ScriptedDriver(events: [
                .textDelta(answer.content), .assistantMessageSaved(answer),
                .textDelta("Next round."), .error(.cancelled)
            ]),
            messageRepository: messages, toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(), availableModels: [SelectableModel(model)]
        )
        vm._setSnapshotState(items: [.userBubble(id: "u1", text: "Question", references: [])])
        vm.send("Question")
        await vm._waitForPendingStreamTask()
        #expect(vm.items.map(\.id) == ["u1", "a1"])
        #expect(vm.interruptedResponse?.text == "Next round.")
    }

    @Test("failed initial projection defers turn focus until the row is available")
    func failedProjectionDefersFocus() async {
        let user = MessageRecord(id: "u1", conversationId: conversationId, role: .user, content: "Question", createdAt: Date())
        let messages = StubMessageRepository(initial: [user])
        await messages.failNextFetch()
        let vm = ChatScreenViewModel(
            conversationId: conversationId, conversationTitle: "Test",
            driver: ScriptedDriver(events: [.userMessageSaved(user)]),
            messageRepository: messages, toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(), availableModels: [SelectableModel(model)]
        )
        vm.send("Question")
        await vm._waitForPendingStreamTask()
        #expect(vm.items.map(\.id) == ["u1"])
        #expect(vm.scrollRequest == .init(messageID: "u1", sequence: 1))
    }

    @Test("interrupted output remains in memory until retry", arguments: [false, true])
    func interruptedResponseIsRetained(cancelled: Bool) async {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_000))
        let user = MessageRecord(id: "u1", conversationId: conversationId, role: .user, content: "Question", createdAt: Date())
        let messages = StubMessageRepository(initial: [user])
        let vm = ChatScreenViewModel(
            conversationId: conversationId, conversationTitle: "Test",
            driver: ScriptedDriver(events: [
                .userMessageSaved(user), .thinkingDelta("Reasoning."), .textDelta("Partial reply."),
                .error(cancelled ? .cancelled : .unauthorized)
            ]),
            messageRepository: messages, toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(), availableModels: [SelectableModel(model)], clock: clock
        )
        vm.send("Question")
        await vm._waitForPendingStreamTask()
        #expect(vm.streamingTail == nil)
        #expect(!vm.isStreaming)
        #expect(vm.interruptedResponse?.text == "Partial reply.")
        #expect(vm.interruptedResponse?.thinking == "Reasoning.")
        #expect(vm.interruptedResponse?.thinkingDurationMs == 0)
        #expect(vm.items.map(\.id) == ["u1"])
        #expect(vm.scrollRequest == .init(messageID: "u1", sequence: 1))
        vm.retry()
        #expect(vm.interruptedResponse == nil)
        #expect(vm.scrollRequest == .init(messageID: "u1", sequence: 2))
        await vm._waitForPendingStreamTask()
    }

    @Test("send accumulates streaming text into the tail until completion")
    func streamingTextAccumulatesThenClears() async throws {
        let driver = ScriptedDriver(events: [
            .userMessageSaved(MessageRecord(id: "u1", conversationId: conversationId, role: .user, content: "hi", createdAt: Date())),
            .textDelta("Hel"),
            .textDelta("lo"),
            .assistantMessageSaved(MessageRecord(id: "a1", conversationId: conversationId, role: .assistant, content: "Hello", createdAt: Date())),
        ])
        let messages = StubMessageRepository(initial: [])
        let toolCalls = StubToolCallRepository()
        let checkpoints = StubCheckpointRepository()
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: messages,
            toolCallRepository: toolCalls,
            checkpointRepository: checkpoints,
            availableModels: [SelectableModel(model)]
        )

        // Seed post-write rows before broadcasting the event that triggers a repository refresh.
        let savedUser = MessageRecord(id: "u1", conversationId: conversationId, role: .user, content: "hi", createdAt: Date())
        let savedAssistant = MessageRecord(id: "a1", conversationId: conversationId, role: .assistant, content: "Hello", createdAt: Date().addingTimeInterval(1))
        await messages.set([savedUser, savedAssistant])

        viewModel.send("hi")
        try await driver.waitUntilFinished()
        await viewModel._waitForPendingStreamTask()

        #expect(viewModel.isStreaming == false)
        #expect(viewModel.streamingTail == nil)
        #expect(viewModel.items.count == 2)
        #expect(viewModel.scrollRequest == .init(messageID: "u1", sequence: 1))
        #expect(viewModel.interruptedResponse == nil)
        #expect(viewModel.error == nil)
    }

    @Test("error event surfaces as banner")
    func errorEventSurfacesAsBanner() async throws {
        let driver = ScriptedDriver(events: [
            .userMessageSaved(MessageRecord(id: "u1", conversationId: conversationId, role: .user, content: "hi", createdAt: Date())),
            .error(.unauthorized),
        ])
        let messages = StubMessageRepository(initial: [])
        await messages.set([
            MessageRecord(id: "u1", conversationId: conversationId, role: .user, content: "hi", createdAt: Date())
        ])
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: messages,
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)]
        )

        viewModel.send("hi")
        try await driver.waitUntilFinished()
        await viewModel._waitForPendingStreamTask()

        #expect(viewModel.error?.message.contains("Authentication failed") == true)
    }

    @Test("retry routes through driver.retry, not driver.send, so no duplicate user row is written")
    func retryInvokesDriverRetryNotSend() async {
        let driver = RecordingDriver()
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: StubMessageRepository(),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)]
        )
        // Retry requires an existing user bubble, as a failed production turn would leave.
        viewModel._setSnapshotState(
            items: [
                .userBubble(id: "u1", text: "test", references: [])
            ],
            error: MessageList.ErrorState(message: "Authentication failed.")
        )

        viewModel.retry()
        await driver.waitForRetry()
        await viewModel._waitForPendingStreamTask()

        #expect(viewModel.scrollRequest == .init(messageID: "u1", sequence: 1))
        #expect(await driver.retryInvocations == 1)
        #expect(await driver.sendInvocationCount == 0)
        #expect(viewModel.error == nil)
    }

    @Test("confirmSearch routes the tool-call id to the driver")
    func confirmSearchRoutesToDriver() async {
        let driver = RecordingDriver()
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: StubMessageRepository(),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)]
        )
        viewModel.confirmSearch(id: "tc-search")
        await driver.waitForSearchDecision()
        #expect(await driver.confirmedToolCallIDs == ["tc-search"])
        #expect(await driver.skippedToolCallIDs.isEmpty)
    }

    @Test("skipSearch routes the tool-call id to the driver")
    func skipSearchRoutesToDriver() async {
        let driver = RecordingDriver()
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: StubMessageRepository(),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)]
        )
        viewModel.skipSearch(id: "tc-search")
        await driver.waitForSearchDecision()
        #expect(await driver.skippedToolCallIDs == ["tc-search"])
        #expect(await driver.confirmedToolCallIDs.isEmpty)
    }

    @Test("retry while a stream is in flight is a silent no-op")
    func retryWhileStreamingIsANoOp() async {
        // Overlapping consumers would concurrently mutate the same streaming tail.
        let driver = RecordingDriver()
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: StubMessageRepository(),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)]
        )
        // The snapshot seam requires streamingTail != nil exactly when isStreaming is true.
        viewModel._setSnapshotState(
            items: [.userBubble(id: "u1", text: "test", references: [])],
            streamingTail: MessageList.StreamingState(
                thinking: "", thinkingStartedAt: nil, text: "", isCompacting: false
            ),
            error: MessageList.ErrorState(message: "Authentication failed."),
            isStreaming: true
        )

        viewModel.retry()

        #expect(await driver.retryInvocations == 0)
        #expect(await driver.sendInvocationCount == 0)
        #expect(viewModel.isStreaming == true)
        #expect(viewModel.error?.message.contains("Authentication failed") == true)
    }

    @Test("retry after an LLM error does not duplicate the user bubble in the transcript")
    func retryDoesNotDuplicateUserBubble() async throws {
        let userRow = MessageRecord(
            id: "u1",
            conversationId: conversationId,
            role: .user,
            content: "test",
            createdAt: Date()
        )
        let assistantRow = MessageRecord(
            id: "a1",
            conversationId: conversationId,
            role: .assistant,
            content: "ok",
            createdAt: Date().addingTimeInterval(1)
        )
        let messages = StubMessageRepository(initial: [])
        await messages.set([userRow])

        let driver = ScriptedDriver(
            events: [
                .userMessageSaved(userRow),
                .error(.unauthorized),
            ],
            retryEvents: [
                .textDelta("ok"),
                .assistantMessageSaved(assistantRow),
            ]
        )
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: messages,
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)]
        )

        viewModel.send("test")
        await viewModel._waitForPendingStreamTask()
        let userBubbleCountAfterError = viewModel.items.filter {
            if case .userBubble = $0 { return true }
            return false
        }.count
        #expect(userBubbleCountAfterError == 1)
        #expect(viewModel.error?.message.contains("Authentication failed") == true)

        await messages.set([userRow, assistantRow])

        viewModel.retry()
        await viewModel._waitForPendingStreamTask()

        let userBubbleCountAfterRetry = viewModel.items.filter {
            if case .userBubble = $0 { return true }
            return false
        }.count
        #expect(userBubbleCountAfterRetry == 1)
        #expect(viewModel.error == nil)
        #expect(viewModel.items.contains(where: {
            if case .assistantText = $0 { return true }
            return false
        }))
    }

    @Test("send surfaces no-model error and preserves composer text when no model is available")
    func sendSurfacesNoModelErrorWhenNoModel() {
        let driver = ScriptedDriver(events: [])
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: StubMessageRepository(),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: []
        )
        viewModel.composerText = "hi"

        viewModel.send("hi")
        #expect(viewModel.isStreaming == false)
        #expect(viewModel.composerText == "hi")
        #expect(viewModel.error?.kind == .noModelConfigured)
        #expect(viewModel.error?.message == "Add a model to send messages.")
        #expect(viewModel.scrollRequest == nil)
        #expect(viewModel.error?.actionLabel == "Add model")
        #expect(viewModel.items.isEmpty)
    }

    @Test("no-model error banner action invokes onAddModelRequested")
    func noModelErrorActionInvokesCallback() {
        let driver = ScriptedDriver(events: [])
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: StubMessageRepository(),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: []
        )
        let counter = MainActorCounter()
        viewModel.onAddModelRequested = { counter.value += 1 }

        viewModel.send("hi")
        viewModel.error?.action?()

        #expect(counter.value == 1)
    }

    @Test("setAvailableModels clears no-model error once any model becomes available")
    func setAvailableModelsClearsNoModelError() {
        let driver = ScriptedDriver(events: [])
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: StubMessageRepository(),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: []
        )
        viewModel.send("hi")
        #expect(viewModel.error?.kind == .noModelConfigured)

        viewModel.setAvailableModels([SelectableModel(model)])

        #expect(viewModel.error == nil)
        #expect(viewModel.availableModels.count == 1)
    }

    @Test("send preserves composer text for slash commands so a rejection is retryable")
    func sendPreservesComposerTextForSlashCommands() {
        // Keep a rejected /compact command in the composer because no user bubble records it.
        let driver = ScriptedDriver(events: [])
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: StubMessageRepository(),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)]
        )
        viewModel.composerText = "/compact"

        viewModel.send("/compact")

        #expect(viewModel.composerText == "/compact")
        #expect(viewModel.isStreaming == true)
    }

    @Test("send clears composer text for ordinary (non-slash) submissions")
    func sendClearsComposerTextForOrdinarySubmissions() {
        let driver = ScriptedDriver(events: [])
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: StubMessageRepository(),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)]
        )
        viewModel.composerText = "Hello there"

        viewModel.send("Hello there")

        #expect(viewModel.composerText == "")
        #expect(viewModel.isStreaming == true)
    }

    @Test("send with a model clears a pre-existing error before streaming")
    func sendWithModelClearsExistingError() {
        let driver = ScriptedDriver(events: [])
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: StubMessageRepository(),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)]
        )
        viewModel._setSnapshotState(
            items: [],
            error: MessageList.ErrorState(message: "Earlier failure")
        )

        viewModel.send("hi")

        #expect(viewModel.error == nil)
        #expect(viewModel.isStreaming == true)
    }

    @Test("setAvailableModels does not clear unrelated generic errors")
    func setAvailableModelsLeavesGenericErrorsAlone() {
        let driver = ScriptedDriver(events: [])
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: StubMessageRepository(),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: []
        )
        viewModel._setSnapshotState(
            items: [],
            error: MessageList.ErrorState(message: "Authentication failed.")
        )

        viewModel.setAvailableModels([SelectableModel(model)])

        #expect(viewModel.error?.kind == .generic)
        #expect(viewModel.error?.message == "Authentication failed.")
    }

    @Test("load attaches to an in-flight turn and hydrates streamingTail from the snapshot")
    func loadAttachesToLiveTurnAndHydratesStreamingTail() async throws {
        // Hydrate before consuming events so remounting cannot flash an empty streaming tail.
        let savedAssistant = MessageRecord(
            id: "a1",
            conversationId: conversationId,
            role: .assistant,
            content: "in progress more",
            createdAt: Date()
        )
        let snapshot = ChatSession.LiveTurnSnapshot(
            accumulatedText: "in progress",
            accumulatedThinking: ""
        )
        let driver = ScriptedDriver(
            events: [],
            pendingSnapshot: snapshot,
            pendingSubscribeEvents: [
                .textDelta(" more"),
                .assistantMessageSaved(savedAssistant),
            ]
        )
        let messages = StubMessageRepository(initial: [savedAssistant])
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: messages,
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)]
        )

        await viewModel.load()

        // No main-actor yield has occurred since load(), so these values still reflect the snapshot.
        #expect(viewModel.streamingTail?.text == "in progress")
        #expect(viewModel.isStreaming == true)

        await viewModel._waitForPendingStreamTask()

        #expect(viewModel.isStreaming == false)
        #expect(viewModel.streamingTail == nil)
        let hasAssistantText = viewModel.items.contains { item in
            if case .assistantText(_, _, _, let text, _, _, _, _, _) = item {
                return text == "in progress more"
            }
            return false
        }
        #expect(hasAssistantText, "subsequent events from the subscribed stream must drive items to the final state")
    }

    @Test("load is idempotent during a live turn — re-mount must not double-subscribe (regression)")
    func loadIsIdempotentDuringLiveTurn() async throws {
        // Remounts call load() again. A second subscription would append each delta twice.
        let snapshot = ChatSession.LiveTurnSnapshot(
            accumulatedText: "in progress",
            accumulatedThinking: ""
        )
        let driver = HangingSubscribeDriver(pendingSnapshot: snapshot)
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: StubMessageRepository(),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)]
        )

        await viewModel.load()
        var subscribeCount = await driver.subscribeCount
        #expect(subscribeCount == 1)
        #expect(viewModel.isStreaming == true)
        #expect(viewModel.streamingTail?.text == "in progress")

        await viewModel.load()
        subscribeCount = await driver.subscribeCount
        #expect(subscribeCount == 1, "remount must not re-subscribe while the first stream is still active")
        #expect(viewModel.streamingTail?.text == "in progress", "snapshot text must not be re-applied on a remount")

        await driver.closeStream()
        await viewModel._waitForPendingStreamTask()
        #expect(viewModel.isStreaming == false)
    }

    @Test("load propagates snapshot.thinkingStartedAt into the streaming tail so the elapsed-time counter survives detach + reattach")
    func loadPropagatesSnapshotThinkingStartedAt() async throws {
        let originalStart = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = ChatSession.LiveTurnSnapshot(
            accumulatedText: "",
            accumulatedThinking: "reasoning so far",
            thinkingStartedAt: originalStart
        )
        let driver = ScriptedDriver(
            events: [],
            pendingSnapshot: snapshot,
            pendingSubscribeEvents: []
        )
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: StubMessageRepository(),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)]
        )

        await viewModel.load()

        #expect(viewModel.streamingTail?.thinking == "reasoning so far")
        #expect(viewModel.streamingTail?.thinkingStartedAt == originalStart)
    }

    @Test("cancelStreaming routes through the driver so the underlying session is cancelled")
    func cancelStreamingInvokesDriverCancel() async throws {
        // Stream disposal leaves session work running; Stop must explicitly call driver.cancel().
        let driver = ScriptedDriver(events: [])
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: StubMessageRepository(),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)]
        )

        viewModel.cancelStreaming()
        await viewModel._waitForPendingCancelTask()

        let count = await driver.cancelCount()
        #expect(count == 1)
    }

    @Test("send trims whitespace and ignores empty input")
    func sendTrimsWhitespace() {
        let driver = ScriptedDriver(events: [])
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: StubMessageRepository(),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)]
        )

        viewModel.send("   ")
        #expect(viewModel.isStreaming == false)
    }

    @Test("compactionStarted flips the tail's isCompacting flag on")
    func compactionStartedSurfacesInTail() async throws {
        let driver = ScriptedDriver(events: [
            .userMessageSaved(MessageRecord(id: "u1", conversationId: conversationId, role: .user, content: "/compact", createdAt: Date())),
            .compactionStarted,
        ])
        let messages = StubMessageRepository(initial: [])
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: messages,
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)]
        )

        viewModel.send("/compact")
        try await driver.waitUntilFinished()
        for _ in 0..<200 {
            if viewModel.streamingTail?.isCompacting == true { break }
            await Task.yield()
        }

        await viewModel._waitForPendingStreamTask()
        #expect(viewModel.isStreaming == false)
    }

    // MARK: - Auto-title generation

    @Test("First assistant message triggers title generation, persists row, fires hook")
    func autoTitleFiresOnFirstAssistantMessage() async throws {
        let savedUser = MessageRecord(id: "u1", conversationId: conversationId, role: .user, content: "Plan a Lisbon trip", createdAt: Date())
        let savedAssistant = MessageRecord(id: "a1", conversationId: conversationId, role: .assistant, content: "Sure — here is a starter itinerary.", createdAt: Date().addingTimeInterval(1))

        let driver = ScriptedDriver(events: [
            .userMessageSaved(savedUser),
            .assistantMessageSaved(savedAssistant),
        ])
        let messages = StubMessageRepository(initial: [])
        await messages.set([savedUser, savedAssistant])

        let conversations = StubConversationRepository(initial: [
            ConversationRecord(id: conversationId, title: "New chat", createdAt: Date(), updatedAt: Date())
        ])

        let titleProvider = FakeLLMProvider(model: model)
        await titleProvider.enqueue([
            .messageStart(id: "t1", model: model.id),
            .textDelta(index: 0, text: "Lisbon trip plan"),
            .messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 4)),
        ])
        let registry = LLMProviderRegistry()
        await registry.register(titleProvider)
        let titleGen = await makeTitleGenerator(registry: registry)

        let firedTitles = TitleSpy()
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "New chat",
            driver: driver,
            messageRepository: messages,
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)],
            conversationRepository: conversations,
            titleGenerator: titleGen
        )
        viewModel.onTitleGenerated = { title in firedTitles.append(title) }

        viewModel.send("Plan a Lisbon trip")
        try await driver.waitUntilFinished()
        // Stream completion spawns the title task; drain them in that order before reading titles.
        await viewModel._waitForPendingStreamTask()
        await viewModel._waitForPendingTitleTask()

        #expect(viewModel.headerTitle == "Lisbon trip plan")
        let stored = try await conversations.fetch(id: conversationId)
        #expect(stored?.title == "Lisbon trip plan")

        let firedSnapshot = firedTitles.values
        #expect(firedSnapshot == ["Plan a Lisbon trip", "Lisbon trip plan"])
    }

    @Test("Auto-title does not fire on subsequent assistant messages")
    func autoTitleSkipsSecondAssistantMessage() async throws {
        let savedUser = MessageRecord(id: "u1", conversationId: conversationId, role: .user, content: "Hi", createdAt: Date())
        let savedAssistantA = MessageRecord(id: "a1", conversationId: conversationId, role: .assistant, content: "Hello", createdAt: Date().addingTimeInterval(1))
        let savedAssistantB = MessageRecord(id: "a2", conversationId: conversationId, role: .assistant, content: "Anything else?", createdAt: Date().addingTimeInterval(2))

        let driver = ScriptedDriver(events: [
            .userMessageSaved(savedUser),
            .assistantMessageSaved(savedAssistantA),
            .assistantMessageSaved(savedAssistantB),
        ])
        let messages = StubMessageRepository(initial: [])
        await messages.set([savedUser, savedAssistantA, savedAssistantB])

        let conversations = StubConversationRepository(initial: [
            ConversationRecord(id: conversationId, title: "New chat", createdAt: Date(), updatedAt: Date())
        ])

        let titleProvider = FakeLLMProvider(model: model)
        await titleProvider.enqueue([
            .messageStart(id: "t1", model: model.id),
            .textDelta(index: 0, text: "Greeting chat"),
            .messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 2)),
        ])
        let registry = LLMProviderRegistry()
        await registry.register(titleProvider)

        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "New chat",
            driver: driver,
            messageRepository: messages,
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)],
            conversationRepository: conversations,
            titleGenerator: await makeTitleGenerator(registry: registry)
        )

        viewModel.send("Hi")
        try await driver.waitUntilFinished()
        await viewModel._waitForPendingStreamTask()
        await viewModel._waitForPendingTitleTask()

        let captured = await titleProvider.capturedRequests()
        #expect(captured.count == 1)
        #expect(viewModel.headerTitle == "Greeting chat")
    }

    @Test("Auto-title is skipped when the conversation already has a real title")
    func autoTitleSkippedWhenTitleAlreadySet() async throws {
        let savedUser = MessageRecord(id: "u1", conversationId: conversationId, role: .user, content: "Continue", createdAt: Date())
        let savedAssistant = MessageRecord(id: "a1", conversationId: conversationId, role: .assistant, content: "Continuing.", createdAt: Date().addingTimeInterval(1))

        let driver = ScriptedDriver(events: [
            .userMessageSaved(savedUser),
            .assistantMessageSaved(savedAssistant),
        ])
        let messages = StubMessageRepository(initial: [savedUser, savedAssistant])
        let conversations = StubConversationRepository(initial: [
            ConversationRecord(id: conversationId, title: "Trip plan", createdAt: Date(), updatedAt: Date())
        ])

        let titleProvider = FakeLLMProvider(model: model)
        let registry = LLMProviderRegistry()
        await registry.register(titleProvider)

        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Trip plan",
            driver: driver,
            messageRepository: messages,
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)],
            conversationRepository: conversations,
            titleGenerator: await makeTitleGenerator(registry: registry)
        )

        viewModel.send("Continue")
        try await driver.waitUntilFinished()
        await viewModel._waitForPendingStreamTask()
        await viewModel._waitForPendingTitleTask()

        let captured = await titleProvider.capturedRequests()
        #expect(captured.isEmpty)
        #expect(viewModel.headerTitle == "Trip plan")
    }

    @Test("Auto-title is skipped when the assistant message has no text yet")
    func autoTitleSkippedForEmptyAssistantMessage() async throws {
        let savedUser = MessageRecord(id: "u1", conversationId: conversationId, role: .user, content: "Hi", createdAt: Date())
        let savedAssistantToolOnly = MessageRecord(id: "a1", conversationId: conversationId, role: .assistant, content: "", createdAt: Date().addingTimeInterval(1))

        let driver = ScriptedDriver(events: [
            .userMessageSaved(savedUser),
            .assistantMessageSaved(savedAssistantToolOnly),
        ])
        let messages = StubMessageRepository(initial: [savedUser, savedAssistantToolOnly])
        let conversations = StubConversationRepository(initial: [
            ConversationRecord(id: conversationId, title: "New chat", createdAt: Date(), updatedAt: Date())
        ])

        let titleProvider = FakeLLMProvider(model: model)
        let registry = LLMProviderRegistry()
        await registry.register(titleProvider)

        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "New chat",
            driver: driver,
            messageRepository: messages,
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)],
            conversationRepository: conversations,
            titleGenerator: await makeTitleGenerator(registry: registry)
        )

        viewModel.send("Hi")
        try await driver.waitUntilFinished()
        await viewModel._waitForPendingStreamTask()
        await viewModel._waitForPendingTitleTask()

        let captured = await titleProvider.capturedRequests()
        #expect(captured.isEmpty)
        #expect(viewModel.headerTitle == "Hi")
    }

    @Test("Auto-title generator returning nil leaves the header alone and clears the once-flag")
    func autoTitleGeneratorNilLeavesPlaceholderAndAllowsRetry() async throws {
        let savedUser = MessageRecord(id: "u1", conversationId: conversationId, role: .user, content: "Hi", createdAt: Date())
        let savedAssistant = MessageRecord(id: "a1", conversationId: conversationId, role: .assistant, content: "Hello", createdAt: Date().addingTimeInterval(1))

        let driver = ScriptedDriver(events: [
            .userMessageSaved(savedUser),
            .assistantMessageSaved(savedAssistant),
        ])
        let messages = StubMessageRepository(initial: [savedUser, savedAssistant])
        let conversations = StubConversationRepository(initial: [
            ConversationRecord(id: conversationId, title: "New chat", createdAt: Date(), updatedAt: Date())
        ])

        let titleProvider = FakeLLMProvider(model: model)
        await titleProvider.enqueue([
            .messageStart(id: "t1", model: model.id),
            .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
        ])
        let registry = LLMProviderRegistry()
        await registry.register(titleProvider)

        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "New chat",
            driver: driver,
            messageRepository: messages,
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)],
            conversationRepository: conversations,
            titleGenerator: await makeTitleGenerator(registry: registry)
        )

        viewModel.send("Hi")
        try await driver.waitUntilFinished()
        await viewModel._waitForPendingStreamTask()
        await viewModel._waitForPendingTitleTask()

        let stored = try await conversations.fetch(id: conversationId)
        #expect(stored?.title == "Hi")
        #expect(viewModel.headerTitle == "Hi")
    }

    @Test("First user message stamps a truncated fallback title before the LLM responds")
    func userSendStampsTruncatedFallbackTitle() async throws {
        let savedUser = MessageRecord(id: "u1", conversationId: conversationId, role: .user, content: "How do I reset my password on Linux?", createdAt: Date())

        let driver = ScriptedDriver(events: [
            .userMessageSaved(savedUser),
        ])
        let messages = StubMessageRepository(initial: [savedUser])
        let conversations = StubConversationRepository(initial: [
            ConversationRecord(id: conversationId, title: "New chat", createdAt: Date(), updatedAt: Date())
        ])

        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "New chat",
            driver: driver,
            messageRepository: messages,
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)],
            conversationRepository: conversations
        )

        viewModel.send("How do I reset my password on Linux?")
        try await driver.waitUntilFinished()
        await viewModel._waitForPendingStreamTask()

        #expect(viewModel.headerTitle == "How do I reset my pa…")
        let stored = try await conversations.fetch(id: conversationId)
        #expect(stored?.title == "How do I reset my pa…")
    }

    @Test("LLM-generated title overwrites the truncated fallback")
    func llmTitleOverwritesTruncatedFallback() async throws {
        let savedUser = MessageRecord(id: "u1", conversationId: conversationId, role: .user, content: "Plan a Lisbon trip with kids", createdAt: Date())
        let savedAssistant = MessageRecord(id: "a1", conversationId: conversationId, role: .assistant, content: "Sure — here is a starter itinerary.", createdAt: Date().addingTimeInterval(1))

        let driver = ScriptedDriver(events: [
            .userMessageSaved(savedUser),
            .assistantMessageSaved(savedAssistant),
        ])
        let messages = StubMessageRepository(initial: [savedUser, savedAssistant])
        let conversations = StubConversationRepository(initial: [
            ConversationRecord(id: conversationId, title: "New chat", createdAt: Date(), updatedAt: Date())
        ])

        let titleProvider = FakeLLMProvider(model: model)
        await titleProvider.enqueue([
            .messageStart(id: "t1", model: model.id),
            .textDelta(index: 0, text: "Lisbon trip plan"),
            .messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 4)),
        ])
        let registry = LLMProviderRegistry()
        await registry.register(titleProvider)

        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "New chat",
            driver: driver,
            messageRepository: messages,
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)],
            conversationRepository: conversations,
            titleGenerator: await makeTitleGenerator(registry: registry)
        )

        viewModel.send("Plan a Lisbon trip with kids")
        try await driver.waitUntilFinished()
        await viewModel._waitForPendingStreamTask()
        await viewModel._waitForPendingTitleTask()

        let stored = try await conversations.fetch(id: conversationId)
        #expect(stored?.title == "Lisbon trip plan")
    }

    @Test("Second user-send does not replace an existing fallback or LLM title")
    func secondUserSendDoesNotOverwriteTitle() async throws {
        let firstUser = MessageRecord(id: "u1", conversationId: conversationId, role: .user, content: "Plan a Lisbon trip with kids", createdAt: Date())
        let secondUser = MessageRecord(id: "u2", conversationId: conversationId, role: .user, content: "What about Madrid instead?", createdAt: Date().addingTimeInterval(2))

        let driver = ScriptedDriver(events: [
            .userMessageSaved(firstUser),
            .userMessageSaved(secondUser),
        ])
        let messages = StubMessageRepository(initial: [firstUser, secondUser])
        let conversations = StubConversationRepository(initial: [
            ConversationRecord(id: conversationId, title: "New chat", createdAt: Date(), updatedAt: Date())
        ])

        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "New chat",
            driver: driver,
            messageRepository: messages,
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)],
            conversationRepository: conversations
        )

        viewModel.send("Plan a Lisbon trip with kids")
        try await driver.waitUntilFinished()
        await viewModel._waitForPendingStreamTask()

        let stored = try await conversations.fetch(id: conversationId)
        #expect(stored?.title == "Plan a Lisbon trip w…")
        #expect(viewModel.headerTitle == "Plan a Lisbon trip w…")
    }

    @Test("Truncation fallback is skipped when the conversation already has a real title")
    func fallbackSkippedWhenTitleAlreadySet() async throws {
        let savedUser = MessageRecord(id: "u1", conversationId: conversationId, role: .user, content: "Continue", createdAt: Date())

        let driver = ScriptedDriver(events: [
            .userMessageSaved(savedUser),
        ])
        let messages = StubMessageRepository(initial: [savedUser])
        let conversations = StubConversationRepository(initial: [
            ConversationRecord(id: conversationId, title: "Trip plan", createdAt: Date(), updatedAt: Date())
        ])

        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Trip plan",
            driver: driver,
            messageRepository: messages,
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)],
            conversationRepository: conversations
        )

        viewModel.send("Continue")
        try await driver.waitUntilFinished()
        await viewModel._waitForPendingStreamTask()

        let stored = try await conversations.fetch(id: conversationId)
        #expect(stored?.title == "Trip plan")
        #expect(viewModel.headerTitle == "Trip plan")
    }

    @Test("truncatedFallback returns nil for empty input and ellipsizes only when shortened")
    func truncatedFallbackEdgeCases() {
        #expect(ChatScreenViewModel.truncatedFallback(for: "") == nil)
        #expect(ChatScreenViewModel.truncatedFallback(for: "    ") == nil)
        #expect(ChatScreenViewModel.truncatedFallback(for: "Short") == "Short")
        #expect(ChatScreenViewModel.truncatedFallback(for: "Exactly twenty chars!") == "Exactly twenty chars…")
        let long = ChatScreenViewModel.truncatedFallback(for: "How do I reset my password on Linux?")
        #expect(long == "How do I reset my pa…")
    }

    @Test("titleNeedsGeneration treats nil, empty, and 'New chat' as placeholders")
    func titleNeedsGenerationPlaceholderRules() {
        #expect(ChatScreenViewModel.titleNeedsGeneration(nil) == true)
        #expect(ChatScreenViewModel.titleNeedsGeneration("") == true)
        #expect(ChatScreenViewModel.titleNeedsGeneration("   ") == true)
        #expect(ChatScreenViewModel.titleNeedsGeneration("New chat") == true)
        #expect(ChatScreenViewModel.titleNeedsGeneration("new chat") == true)
        #expect(ChatScreenViewModel.titleNeedsGeneration("Lisbon trip plan") == false)
    }


    // MARK: - Voice input wiring

    @Test("empty final after a pause preserves the last recognized words")
    func emptyVoiceFinalPreservesDraftAndSpeech() async {
        let service = FakeVoiceInputService()
        let voice = VoiceInputController(service: service)
        let viewModel = makeVoiceViewModel(voice: voice)
        viewModel.composerText = "draft"
        var processed = voice._observeProcessedEvents().makeAsyncIterator()
        await viewModel.handleMicTap()
        service.emit(.partial("hello"))
        await processed.next()
        await viewModel._waitForVoiceUpdates()
        service.emit(.final(""))
        await processed.next()
        await viewModel._waitForVoiceUpdates()
        #expect(viewModel.composerText == "draft hello")
    }

    @Test("voice appends to the current draft rather than a start-time snapshot")
    func voiceFinalPreservesCurrentDraft() async {
        let service = FakeVoiceInputService()
        let voice = VoiceInputController(service: service)
        let viewModel = makeVoiceViewModel(voice: voice)
        viewModel.composerText = "draft"
        var processed = voice._observeProcessedEvents().makeAsyncIterator()
        await viewModel.handleMicTap()
        viewModel.composerText = "edited draft"
        service.emit(.final("hello"))
        await processed.next()
        await viewModel._waitForVoiceUpdates()
        #expect(viewModel.composerText == "edited draft hello")
    }

    @Test("switching chats releases narration's microphone gate")
    func detachingChatStopsVoiceCapture() async {
        let activity = AudioActivity()
        let voice = VoiceInputController(service: FakeVoiceInputService(), audioActivity: activity)
        let viewModel = makeVoiceViewModel(voice: voice)
        await viewModel.handleMicTap()
        #expect(activity.isCapturing)

        viewModel.detachFromLiveTurn()
        #expect(voice.state == .stopping)
        #expect(!activity.isCapturing)

        let next = VoiceInputController(service: FakeVoiceInputService(), audioActivity: activity)
        await next.toggle()
        viewModel.detachFromLiveTurn()
        #expect(activity.isCapturing)
        next.stop()
    }

    @Test("detaching during microphone permission cannot start a stale capture")
    func detachingChatCancelsPendingVoiceCapture() async {
        let activity = AudioActivity()
        let service = FakeVoiceInputService()
        let gate = service.gatePermissions()
        let voice = VoiceInputController(service: service, audioActivity: activity)
        let viewModel = makeVoiceViewModel(voice: voice)
        async let pending: Void = viewModel.handleMicTap()
        await gate.waitUntilEntered()
        viewModel.detachFromLiveTurn()
        let next = VoiceInputController(service: FakeVoiceInputService(), audioActivity: activity)
        await next.toggle()
        gate.release()
        await pending
        #expect(service.startCallCount == 0)
        #expect(voice.state == .idle)
        #expect(activity.isCapturing)
        next.stop()
        #expect(!activity.isCapturing)
    }

    @Test("micTap leaves the current composer draft owned by the view model")
    func micTapPreservesComposerOwnership() async {
        let voiceService = FakeVoiceInputService()
        let voice = VoiceInputController(service: voiceService)
        let viewModel = makeVoiceViewModel(voice: voice)
        viewModel.composerText = "draft prefix"

        await viewModel.handleMicTap()

        #expect(viewModel.composerText == "draft prefix")
        #expect(voice.state == .listening)
        #expect(voiceService.startCallCount == 1)
    }

    @Test("final transcript appends to the committed composer prefix")
    func finalTranscriptAppendsToComposerText() async {
        let voiceService = FakeVoiceInputService()
        let voice = VoiceInputController(service: voiceService)
        let viewModel = makeVoiceViewModel(voice: voice)
        viewModel.composerText = "draft"
        var processed = voice._observeProcessedEvents().makeAsyncIterator()

        await viewModel.handleMicTap()
        voiceService.emit(.final("hello"))
        await processed.next()
        await viewModel._waitForVoiceUpdates()

        #expect(viewModel.composerText == "draft hello")
    }

    @Test("pauses append phrases while empty and revised previews leave the draft intact")
    func voicePausesPreserveComposer() async {
        let service = FakeVoiceInputService()
        let voice = VoiceInputController(service: service)
        let viewModel = makeVoiceViewModel(voice: voice)
        var processed = voice._observeProcessedEvents().makeAsyncIterator()
        viewModel.composerText = "draft\n"
        await viewModel.handleMicTap()
        service.emit(.utterance("first"))
        await processed.next()
        await viewModel._waitForVoiceUpdates()
        #expect(viewModel.composerText == "draft\nfirst")
        service.emit(.partial("second"))
        await processed.next()
        await viewModel._waitForVoiceUpdates()
        #expect(viewModel.composerText == "draft\nfirst")
        #expect(viewModel.displayedComposerText == "draft\nfirst second")
        service.emit(.partial(""))
        await processed.next()
        await viewModel._waitForVoiceUpdates()
        #expect(viewModel.displayedComposerText == "draft\nfirst second")
        service.emit(.utterance("Second."))
        await processed.next()
        await viewModel._waitForVoiceUpdates()
        #expect(viewModel.composerText == "draft\nfirst Second.")
        viewModel.handleStopRecording()
        await viewModel._waitForVoiceUpdates()
        #expect(viewModel.displayedComposerText == "draft\nfirst Second.")
        #expect(viewModel.voiceState == .idle)
    }

    @Test("recognition failure preserves both committed and provisional speech")
    func voiceFailurePreservesSpeech() async {
        let service = FakeVoiceInputService()
        let voice = VoiceInputController(service: service)
        let viewModel = makeVoiceViewModel(voice: voice)
        var processed = voice._observeProcessedEvents().makeAsyncIterator()
        await viewModel.handleMicTap()
        service.emit(.utterance("first"))
        await processed.next()
        service.emit(.partial("last"))
        await processed.next()
        service.failNext(with: .recognizerFailed("boom"))
        await processed.next()
        await viewModel._waitForVoiceUpdates()
        #expect(viewModel.composerText == "first last")
        #expect(viewModel.voicePreview == "")
        #expect(viewModel.voiceState == .failed("boom"))
        #expect(viewModel.error?.message == "Voice input failed: boom")
    }

    @Test("detach flushes pending speech to the outgoing draft and releases capture")
    func detachFlushesVoice() async {
        let service = FakeVoiceInputService()
        let voice = VoiceInputController(service: service)
        let viewModel = makeVoiceViewModel(voice: voice)
        var processed = voice._observeProcessedEvents().makeAsyncIterator()
        await viewModel.handleMicTap()
        service.emit(.partial("keep this"))
        await processed.next()
        viewModel.detachFromLiveTurn()
        #expect(!service.isCapturing)
        await viewModel._waitForVoiceUpdates()
        #expect(viewModel.composerText == "keep this")
        #expect(viewModel.voiceState == .idle)
    }

    @Test("send cannot clear the draft before buffered final speech is appended")
    func sendWaitsForVoiceDelivery() async {
        let service = FakeVoiceInputService()
        let voice = VoiceInputController(service: service)
        let viewModel = makeVoiceViewModel(voice: voice)
        var processed = voice._observeProcessedEvents().makeAsyncIterator()
        viewModel.composerText = "draft"
        await viewModel.handleMicTap()
        service.emit(.partial("hello"))
        await processed.next()
        await viewModel._waitForVoiceUpdates()
        viewModel.handleStopRecording()
        // stop enqueues its final append synchronously; the subscriber cannot run
        // before this send attempt on the same main-actor turn.
        viewModel.send("draft")
        #expect(viewModel.composerText == "draft")
        await viewModel._waitForVoiceUpdates()
        #expect(viewModel.composerText == "draft hello")
        #expect(!viewModel.isStreaming)
    }

    @Test("voice restart appends repeated phrases to the current edited draft")
    func voiceRestartUsesCurrentDraft() async {
        let service = FakeVoiceInputService()
        let voice = VoiceInputController(service: service)
        let viewModel = makeVoiceViewModel(voice: voice)
        var processed = voice._observeProcessedEvents().makeAsyncIterator()
        await viewModel.handleMicTap()
        service.emit(.utterance("yes"))
        await processed.next()
        viewModel.handleStopRecording()
        await viewModel.handleMicTap()
        await viewModel._waitForVoiceUpdates()
        viewModel.composerText = "edited yes "
        service.emit(.final("yes"))
        await processed.next()
        await viewModel._waitForVoiceUpdates()
        #expect(viewModel.composerText == "edited yes yes")
    }

    @Test("voice .denied state surfaces a banner with the Settings action")
    func voiceStateDeniedSetsErrorBanner() {
        let voice = VoiceInputController(service: FakeVoiceInputService())
        let viewModel = makeVoiceViewModel(voice: voice)

        viewModel.handleVoiceStateChange(.denied)

        #expect(viewModel.error?.actionLabel == "Settings")
        #expect(viewModel.error?.action != nil)
    }

    @Test("voice .failed state surfaces a banner without action or retry buttons")
    func voiceStateFailedSetsErrorBanner() {
        let voice = VoiceInputController(service: FakeVoiceInputService())
        let viewModel = makeVoiceViewModel(voice: voice)

        viewModel.handleVoiceStateChange(.failed("boom"))

        #expect(viewModel.error?.message.contains("boom") == true)
        #expect(viewModel.error?.actionLabel == nil)
        // Voice Retry must not resend the unrelated last LLM message.
        #expect(viewModel.error?.showsRetry == false)
    }

    @Test("voice .failed with kLSRErrorDomain message uses the dictation-pack hint")
    func voiceStateFailedWithMissingDictationPackUsesHint() {
        let voice = VoiceInputController(service: FakeVoiceInputService())
        let viewModel = makeVoiceViewModel(voice: voice)

        viewModel.handleVoiceStateChange(.failed("kLSRErrorDomain #300: …"))

        #expect(viewModel.error?.message.contains("real device") == true)
        #expect(viewModel.error?.message.contains("Dictation") == true)
        #expect(viewModel.error?.showsRetry == false)
    }

    @Test("voice .unavailable state leaves the existing error banner alone")
    func voiceStateUnavailableLeavesErrorAlone() {
        let voice = VoiceInputController(service: FakeVoiceInputService())
        let viewModel = makeVoiceViewModel(voice: voice)

        viewModel.handleVoiceStateChange(.unavailable)

        #expect(viewModel.error == nil)
    }

    @Test("applyExternalVerbosity updates verbosity when given a non-nil value")
    func applyExternalVerbosityUpdates() {
        let viewModel = makeMinimalViewModel()
        #expect(viewModel.verbosity == .simple)

        viewModel.applyExternalVerbosity(.verbose)
        #expect(viewModel.verbosity == .verbose)

        viewModel.applyExternalVerbosity(.thinking)
        #expect(viewModel.verbosity == .thinking)
    }

    @Test("applyExternalVerbosity is a no-op on nil so an optional observable can pass through directly")
    func applyExternalVerbosityIgnoresNil() {
        let viewModel = makeMinimalViewModel()
        viewModel.applyExternalVerbosity(.verbose)
        #expect(viewModel.verbosity == .verbose)

        viewModel.applyExternalVerbosity(nil)
        #expect(viewModel.verbosity == .verbose)
    }

    private func makeMinimalViewModel() -> ChatScreenViewModel {
        ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: ScriptedDriver(events: []),
            messageRepository: StubMessageRepository(),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)]
        )
    }

    private func makeVoiceViewModel(voice: VoiceInputController) -> ChatScreenViewModel {
        ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: ScriptedDriver(events: []),
            messageRepository: StubMessageRepository(),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)],
            voice: voice
        )
    }

    // MARK: - Verse reference pills

    private func verseReference(_ id: String) -> RecordReference {
        RecordReference(
            appletID: "bible", kind: "verseRange", sourceID: "WEB/JHN/3/\(id)",
            displayLabel: "John 3:\(id) (WEB)", citation: "John 3:\(id) (WEB)",
            snapshot: "verse \(id)", id: id
        )
    }

    private func makeViewModelWithInbox(
        driver: any ChatSessionDriver
    ) -> (viewModel: ChatScreenViewModel, inbox: ChatReferenceInbox) {
        let inbox = ChatReferenceInbox()
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: StubMessageRepository(initial: []),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)],
            referenceInbox: inbox
        )
        return (viewModel, inbox)
    }

    private func publishAndWait(
        _ event: SuperEvent,
        on bus: SuperEventBus,
        inbox: ChatReferenceInbox
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            inbox._onNextEvent { continuation.resume() }
            Task { await bus.publish(event) }
        }
    }

    @Test("adoptPendingReferences drains the inbox into the composer")
    func adoptPendingReferencesDrainsTheInbox() async {
        let (viewModel, inbox) = makeViewModelWithInbox(driver: ScriptedDriver(events: []))
        let bus = SuperEventBus()
        await inbox.attach(to: bus)
        await publishAndWait(
            .recordAddedToChat(reference: verseReference("16"), startNewConversation: false),
            on: bus, inbox: inbox
        )

        viewModel.adoptPendingReferences()

        #expect(viewModel.pendingReferences == [verseReference("16")])
        #expect(inbox.pending.isEmpty)
    }

    @Test("adoptPendingReferences dedupes a doubled bus delivery by id")
    func adoptPendingReferencesDedupesByID() async {
        let (viewModel, inbox) = makeViewModelWithInbox(driver: ScriptedDriver(events: []))
        let bus = SuperEventBus()
        await inbox.attach(to: bus)
        await publishAndWait(
            .recordAddedToChat(reference: verseReference("16"), startNewConversation: false),
            on: bus, inbox: inbox
        )
        await publishAndWait(
            .recordAddedToChat(reference: verseReference("16"), startNewConversation: false),
            on: bus, inbox: inbox
        )

        viewModel.adoptPendingReferences()

        #expect(viewModel.pendingReferences.count == 1)
    }

    @Test("removeReference drops the pill before send")
    func removeReferenceDropsThePill() async {
        let (viewModel, inbox) = makeViewModelWithInbox(driver: ScriptedDriver(events: []))
        let bus = SuperEventBus()
        await inbox.attach(to: bus)
        await publishAndWait(
            .recordAddedToChat(reference: verseReference("16"), startNewConversation: false),
            on: bus, inbox: inbox
        )
        viewModel.adoptPendingReferences()

        viewModel.removeReference(id: "16")

        #expect(viewModel.pendingReferences.isEmpty)
    }

    @Test("send passes attached references to the driver and clears them")
    func sendPassesReferencesToDriverAndClears() async {
        let driver = RecordingDriver()
        let (viewModel, inbox) = makeViewModelWithInbox(driver: driver)
        let bus = SuperEventBus()
        await inbox.attach(to: bus)
        await publishAndWait(
            .recordAddedToChat(reference: verseReference("16"), startNewConversation: false),
            on: bus, inbox: inbox
        )
        viewModel.adoptPendingReferences()

        viewModel.send("Explain this verse")
        await driver.waitForSend()

        #expect(await driver.sentReferences == [[verseReference("16")]])
        #expect(await driver.sentText == ["Explain this verse"])
        #expect(viewModel.pendingReferences.isEmpty)
    }

    @Test("send is allowed with empty text when a reference is attached")
    func sendAllowedWithEmptyTextWhenReferenceAttached() async {
        let driver = RecordingDriver()
        let (viewModel, inbox) = makeViewModelWithInbox(driver: driver)
        let bus = SuperEventBus()
        await inbox.attach(to: bus)
        await publishAndWait(
            .recordAddedToChat(reference: verseReference("16"), startNewConversation: false),
            on: bus, inbox: inbox
        )
        viewModel.adoptPendingReferences()

        viewModel.send("")
        await driver.waitForSend()

        #expect(await driver.sentText == [""])
        #expect(await driver.sentReferences == [[verseReference("16")]])
    }

    @Test("send with neither text nor references is a no-op")
    func sendWithNothingIsANoOp() async {
        let driver = RecordingDriver()
        let (viewModel, _) = makeViewModelWithInbox(driver: driver)

        viewModel.send("   ")

        #expect(await driver.sentText.isEmpty)
        #expect(viewModel.isStreaming == false)
    }

    // MARK: - Copy confirmation pill

    @Test("confirmCopy flips the pill on immediately and clears after the dismissal task drains")
    func confirmCopyFlipsThenAutoDismisses() async {
        let release = SleepGate()
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: RecordingDriver(),
            messageRepository: StubMessageRepository(),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)],
            copyConfirmationSleep: { duration in
                #expect(duration == .seconds(1.2))
                await release.wait()
            }
        )

        viewModel.confirmCopy()
        #expect(viewModel.showCopyConfirmation == true)

        release.release()
        await viewModel._waitForPendingCopyDismissalTask()
        #expect(viewModel.showCopyConfirmation == false)
    }

    @Test("confirmCopy: rapid second tap cancels the prior dismissal task so the pill rides the new timer")
    func confirmCopyRapidSecondTapRestartsTimer() async {
        // Replacing the dwell timer prevents the first tap from dismissing the second tap early.
        let firstEntered = SleepGate()
        let firstRelease = SleepGate()
        let firstFinished = SleepGate()
        let secondRelease = SleepGate()
        let callCount = Mutex(0)
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: RecordingDriver(),
            messageRepository: StubMessageRepository(),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)],
            copyConfirmationSleep: { _ in
                let index = callCount.withLock { count in
                    defer { count += 1 }
                    return count
                }
                if index == 0 {
                    firstEntered.release()
                    await firstRelease.wait()
                    defer { firstFinished.release() }
                    #expect(Task.isCancelled)
                    try Task.checkCancellation()
                } else {
                    #expect(index == 1)
                    await secondRelease.wait()
                    #expect(!Task.isCancelled)
                }
            }
        )

        viewModel.confirmCopy()
        await firstEntered.wait()
        viewModel.confirmCopy()
        firstRelease.release()
        await firstFinished.wait()
        #expect(viewModel.showCopyConfirmation == true)

        secondRelease.release()
        await viewModel._waitForPendingCopyDismissalTask()
        #expect(viewModel.showCopyConfirmation == false)
    }

    // MARK: - Regenerate

    @Test("requestRegeneration: target = last assistant gives count == 1")
    func requestRegenerationOnLastAssistantCountsOne() {
        let viewModel = makeViewModelForRegen()
        viewModel._setSnapshotState(items: [
            .userBubble(id: "u1", text: "hi", references: []),
            .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: "answer", toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
        ])

        viewModel.requestRegeneration(fromAssistantMessageID: "a1")

        #expect(viewModel.pendingRegenerationTargetID == "a1")
        #expect(viewModel.pendingRegenerationDeleteCount == 1)
    }

    @Test("requestRegeneration: target = earlier assistant counts target + every following row")
    func requestRegenerationOnEarlierAssistantCountsTailLength() {
        let viewModel = makeViewModelForRegen()
        viewModel._setSnapshotState(items: [
            .userBubble(id: "u1", text: "q1", references: []),
            .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: "first", toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
            .userBubble(id: "u2", text: "q2", references: []),
            .assistantText(id: "a2", thinking: nil, thinkingDurationMs: nil, text: "second", toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
        ])

        viewModel.requestRegeneration(fromAssistantMessageID: "a1")

        #expect(viewModel.pendingRegenerationTargetID == "a1")
        #expect(viewModel.pendingRegenerationDeleteCount == 3)
    }

    @Test("requestRegeneration: compaction banners between target and tail are excluded from the count")
    func requestRegenerationExcludesCompactionBanners() {
        // Banners are checkpoints, not message rows; exclude them from the deletion count.
        let viewModel = makeViewModelForRegen()
        viewModel._setSnapshotState(items: [
            .userBubble(id: "u1", text: "q1", references: []),
            .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: "answer", toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
            .compactionBanner(id: "cb1", summary: "checkpoint"),
            .userBubble(id: "u2", text: "q2", references: []),
            .assistantText(id: "a2", thinking: nil, thinkingDurationMs: nil, text: "second", toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
        ])

        viewModel.requestRegeneration(fromAssistantMessageID: "a1")

        #expect(viewModel.pendingRegenerationDeleteCount == 3)
    }

    @Test("requestRegeneration: while streaming, dialog state is not staged")
    func requestRegenerationDuringStreamingIsANoOp() {
        let viewModel = makeViewModelForRegen()
        viewModel._setSnapshotState(
            items: [
                .userBubble(id: "u1", text: "hi", references: []),
                .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: "answer", toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
            ],
            streamingTail: MessageList.StreamingState(
                thinking: "", thinkingStartedAt: nil, text: "", isCompacting: false
            ),
            isStreaming: true
        )

        viewModel.requestRegeneration(fromAssistantMessageID: "a1")

        #expect(viewModel.pendingRegenerationTargetID == nil)
        #expect(viewModel.pendingRegenerationDeleteCount == 0)
    }

    @Test("requestRegeneration: unknown id is a silent no-op")
    func requestRegenerationOnUnknownIdIsANoOp() {
        let viewModel = makeViewModelForRegen()
        viewModel._setSnapshotState(items: [
            .userBubble(id: "u1", text: "hi", references: []),
            .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: "answer", toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
        ])

        viewModel.requestRegeneration(fromAssistantMessageID: "does-not-exist")

        #expect(viewModel.pendingRegenerationTargetID == nil)
        #expect(viewModel.pendingRegenerationDeleteCount == 0)
    }

    @Test("requestRegeneration: a user-bubble id is a silent no-op")
    func requestRegenerationRejectsUserBubbleID() {
        let viewModel = makeViewModelForRegen()
        viewModel._setSnapshotState(items: [
            .userBubble(id: "u1", text: "hi", references: []),
            .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: "answer", toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
        ])

        viewModel.requestRegeneration(fromAssistantMessageID: "u1")

        #expect(viewModel.pendingRegenerationTargetID == nil)
        #expect(viewModel.pendingRegenerationDeleteCount == 0)
    }

    @Test("cancelRegeneration: clears the pending dialog state without writes")
    func cancelRegenerationClearsStateOnly() async {
        let driver = RecordingDriver()
        let viewModel = makeViewModelForRegen(driver: driver)
        viewModel._setSnapshotState(items: [
            .userBubble(id: "u1", text: "hi", references: []),
            .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: "answer", toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
        ])
        viewModel.requestRegeneration(fromAssistantMessageID: "a1")

        viewModel.cancelRegeneration()

        #expect(viewModel.pendingRegenerationTargetID == nil)
        #expect(viewModel.pendingRegenerationDeleteCount == 0)
        #expect(await driver.retryInvocations == 0)
        #expect(await driver.sendInvocationCount == 0)
    }

    @Test("confirmRegeneration: trims the persisted tail and drives driver.retry")
    func confirmRegenerationTrimsAndRetries() async {
        let driver = RecordingDriver()
        let userRow = MessageRecord(
            id: "u1", conversationId: conversationId, role: .user, content: "q1", createdAt: Date()
        )
        let firstAssistant = MessageRecord(
            id: "a1", conversationId: conversationId, role: .assistant, content: "first",
            createdAt: Date().addingTimeInterval(1)
        )
        let secondUser = MessageRecord(
            id: "u2", conversationId: conversationId, role: .user, content: "q2",
            createdAt: Date().addingTimeInterval(2)
        )
        let secondAssistant = MessageRecord(
            id: "a2", conversationId: conversationId, role: .assistant, content: "second",
            createdAt: Date().addingTimeInterval(3)
        )
        let messages = StubMessageRepository(initial: [])
        await messages.set([userRow, firstAssistant, secondUser, secondAssistant])

        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: messages,
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)]
        )
        viewModel._setSnapshotState(items: [
            .userBubble(id: "u1", text: "q1", references: []),
            .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: "first", toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
            .userBubble(id: "u2", text: "q2", references: []),
            .assistantText(id: "a2", thinking: nil, thinkingDurationMs: nil, text: "second", toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
        ])

        viewModel.requestRegeneration(fromAssistantMessageID: "a1")
        viewModel.confirmRegeneration()
        await viewModel._waitForPendingRegenerationTask()
        await viewModel._waitForPendingStreamTask()

        let remaining = try? await messages.fetchAll(conversationId: conversationId).map(\.id)
        #expect(remaining == ["u1"])
        #expect(viewModel.pendingRegenerationTargetID == nil)
        #expect(viewModel.scrollRequest == .init(messageID: "u1", sequence: 1))
        #expect(await driver.retryInvocations == 1)
        #expect(await driver.sendInvocationCount == 0)
    }

    @Test("confirmRegeneration: while streaming is a silent no-op")
    func confirmRegenerationDuringStreamingIsANoOp() async {
        let driver = RecordingDriver()
        let messages = StubMessageRepository()
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: messages,
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)]
        )
        viewModel._setSnapshotState(items: [
            .userBubble(id: "u1", text: "hi", references: []),
            .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: "answer", toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
        ])
        viewModel.requestRegeneration(fromAssistantMessageID: "a1")
        viewModel._setSnapshotState(
            items: [
                .userBubble(id: "u1", text: "hi", references: []),
                .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: "answer", toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
            ],
            streamingTail: MessageList.StreamingState(
                thinking: "", thinkingStartedAt: nil, text: "", isCompacting: false
            ),
            isStreaming: true
        )

        viewModel.confirmRegeneration()
        await viewModel._waitForPendingRegenerationTask()

        #expect(await driver.retryInvocations == 0)
        #expect(await driver.sendInvocationCount == 0)
    }

    @Test("confirmRegeneration: with no pending target is a silent no-op")
    func confirmRegenerationWithoutPendingTargetIsANoOp() async {
        let driver = RecordingDriver()
        let viewModel = makeViewModelForRegen(driver: driver)

        viewModel.confirmRegeneration()
        await viewModel._waitForPendingRegenerationTask()

        #expect(await driver.retryInvocations == 0)
    }

    @Test("confirmRegeneration: surfaces an error banner when the trim throws")
    func confirmRegenerationSurfacesError() async {
        let driver = RecordingDriver()
        let userRow = MessageRecord(
            id: "u1", conversationId: conversationId, role: .user, content: "q", createdAt: Date()
        )
        let assistantRow = MessageRecord(
            id: "a1", conversationId: conversationId, role: .assistant, content: "ans",
            createdAt: Date().addingTimeInterval(1)
        )
        let messages = StubMessageRepository(initial: [userRow, assistantRow])
        await messages.setDeleteError(StubError.boom)

        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: messages,
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)]
        )
        viewModel._setSnapshotState(items: [
            .userBubble(id: "u1", text: "q", references: []),
            .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: "ans", toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
        ])

        viewModel.requestRegeneration(fromAssistantMessageID: "a1")
        viewModel.confirmRegeneration()
        await viewModel._waitForPendingRegenerationTask()

        #expect(viewModel.error?.message == "Could not regenerate. Try again.")
        #expect(await driver.retryInvocations == 0)
    }

    @Test("confirmRegeneration: when checkpoint delete throws, no messages are trimmed")
    func confirmRegenerationCheckpointDeleteThrowsLeavesMessagesIntact() async {
        // Delete checkpoints first so a failed first write leaves messages untouched.
        let driver = RecordingDriver()
        let userRow = MessageRecord(
            id: "u1", conversationId: conversationId, role: .user, content: "q", createdAt: Date()
        )
        let assistantRow = MessageRecord(
            id: "a1", conversationId: conversationId, role: .assistant, content: "ans",
            createdAt: Date().addingTimeInterval(1)
        )
        let messages = StubMessageRepository(initial: [userRow, assistantRow])
        let checkpoints = StubCheckpointRepository()
        await checkpoints.seed([
            CompactionCheckpointRecord(
                id: "cp1", conversationId: conversationId, uptoMessageId: "a1",
                summary: "...", tokensBefore: 0, tokensAfter: 0,
                createdAt: Date(), isLive: true
            )
        ])
        await checkpoints.setDeleteError(StubError.boom)

        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: messages,
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: checkpoints,
            availableModels: [SelectableModel(model)]
        )
        viewModel._setSnapshotState(items: [
            .userBubble(id: "u1", text: "q", references: []),
            .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: "ans", toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
        ])

        viewModel.requestRegeneration(fromAssistantMessageID: "a1")
        viewModel.confirmRegeneration()
        await viewModel._waitForPendingRegenerationTask()

        #expect(viewModel.error?.message == "Could not regenerate. Try again.")
        let remainingMessages = try? await messages.fetchAll(conversationId: conversationId).map(\.id)
        #expect(remainingMessages == ["u1", "a1"])
        #expect(await driver.retryInvocations == 0)
    }

    @Test("confirmRegeneration: deletes checkpoints whose anchor is in the trim range")
    func confirmRegenerationDeletesStaleCheckpoint() async {
        // Removing a checkpoint anchor must also remove its now-stale summary from future prompts.
        let driver = RecordingDriver()
        let messages = StubMessageRepository(initial: [
            MessageRecord(id: "u1", conversationId: conversationId, role: .user, content: "q1", createdAt: Date()),
            MessageRecord(id: "a1", conversationId: conversationId, role: .assistant, content: "first",
                          createdAt: Date().addingTimeInterval(1)),
            MessageRecord(id: "u2", conversationId: conversationId, role: .user, content: "q2",
                          createdAt: Date().addingTimeInterval(2)),
            MessageRecord(id: "a2", conversationId: conversationId, role: .assistant, content: "second",
                          createdAt: Date().addingTimeInterval(3)),
        ])
        let stale = CompactionCheckpointRecord(
            id: "cp-stale", conversationId: conversationId, uptoMessageId: "a1",
            summary: "...", tokensBefore: 0, tokensAfter: 0,
            createdAt: Date(), isLive: true
        )
        let checkpoints = StubCheckpointRepository()
        await checkpoints.seed([stale])

        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: messages,
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: checkpoints,
            availableModels: [SelectableModel(model)]
        )
        viewModel._setSnapshotState(items: [
            .userBubble(id: "u1", text: "q1", references: []),
            .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: "first", toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
            .userBubble(id: "u2", text: "q2", references: []),
            .assistantText(id: "a2", thinking: nil, thinkingDurationMs: nil, text: "second", toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
        ])

        viewModel.requestRegeneration(fromAssistantMessageID: "a1")
        viewModel.confirmRegeneration()
        await viewModel._waitForPendingRegenerationTask()

        let remainingCheckpoints = await checkpoints.snapshotRows().map(\.id)
        #expect(remainingCheckpoints.isEmpty)
    }

    @Test("confirmRegeneration: keeps checkpoints whose anchor survives the trim")
    func confirmRegenerationKeepsSurvivingCheckpoint() async {
        let driver = RecordingDriver()
        let messages = StubMessageRepository(initial: [
            MessageRecord(id: "u1", conversationId: conversationId, role: .user, content: "q1", createdAt: Date()),
            MessageRecord(id: "a1", conversationId: conversationId, role: .assistant, content: "first",
                          createdAt: Date().addingTimeInterval(1)),
            MessageRecord(id: "u2", conversationId: conversationId, role: .user, content: "q2",
                          createdAt: Date().addingTimeInterval(2)),
            MessageRecord(id: "a2", conversationId: conversationId, role: .assistant, content: "second",
                          createdAt: Date().addingTimeInterval(3)),
        ])
        let surviving = CompactionCheckpointRecord(
            id: "cp-keep", conversationId: conversationId, uptoMessageId: "a1",
            summary: "...", tokensBefore: 0, tokensAfter: 0,
            createdAt: Date(), isLive: true
        )
        let checkpoints = StubCheckpointRepository()
        await checkpoints.seed([surviving])

        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: messages,
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: checkpoints,
            availableModels: [SelectableModel(model)]
        )
        viewModel._setSnapshotState(items: [
            .userBubble(id: "u1", text: "q1", references: []),
            .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: "first", toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
            .userBubble(id: "u2", text: "q2", references: []),
            .assistantText(id: "a2", thinking: nil, thinkingDurationMs: nil, text: "second", toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
        ])

        viewModel.requestRegeneration(fromAssistantMessageID: "a2")
        viewModel.confirmRegeneration()
        await viewModel._waitForPendingRegenerationTask()

        let remainingCheckpoints = await checkpoints.snapshotRows().map(\.id)
        #expect(remainingCheckpoints == ["cp-keep"])
    }

    private func makeViewModelForRegen(
        driver: RecordingDriver = RecordingDriver(),
        messages: StubMessageRepository = StubMessageRepository()
    ) -> ChatScreenViewModel {
        ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: messages,
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)]
        )
    }
}

@Suite("ChatScreenViewModel haptics")
@MainActor
struct ChatScreenHapticsTests {
    private let conversationId = "conv-haptics"
    private let model = LLMModel(
        id: "test-model",
        displayName: "Test",
        supportsThinking: false,
        supportsTools: true,
        maxContextTokens: 1000
    )

    @Test("a committed send fires .selection, streaming fires ticks, and the turn ends with one .streamCompleted")
    func sendStreamAndCompletionFireHaptics() async throws {
        let driver = ScriptedDriver(events: [
            .userMessageSaved(MessageRecord(id: "u1", conversationId: conversationId, role: .user, content: "hi", createdAt: Date())),
            // Whitespace flushes the coalescer, producing visible streaming ticks.
            .textDelta("Hello "),
            .textDelta("there "),
            .assistantMessageSaved(MessageRecord(id: "a1", conversationId: conversationId, role: .assistant, content: "Hello there", createdAt: Date())),
        ])
        let messages = StubMessageRepository(initial: [])
        await messages.set([
            MessageRecord(id: "u1", conversationId: conversationId, role: .user, content: "hi", createdAt: Date()),
            MessageRecord(id: "a1", conversationId: conversationId, role: .assistant, content: "Hello there", createdAt: Date().addingTimeInterval(1)),
        ])
        let haptics = RecordingHapticsEngine()
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: driver,
            messageRepository: messages,
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)],
            hapticsEngine: haptics
        )

        viewModel.send("hi")
        try await driver.waitUntilFinished()
        await viewModel._waitForPendingStreamTask()

        let played = haptics.played
        #expect(played.first == .selection)
        #expect(played.filter { $0 == .streamCompleted }.count == 1)
        #expect(played.last == .streamCompleted)
        #expect(played.contains(.streamingTick))
    }

    @Test("a send rejected for having no model fires no haptic")
    func rejectedSendFiresNoHaptic() async throws {
        let haptics = RecordingHapticsEngine()
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: ScriptedDriver(events: []),
            messageRepository: StubMessageRepository(initial: []),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [],
            hapticsEngine: haptics
        )

        viewModel.send("hi")

        #expect(haptics.played.isEmpty)
    }

    @Test("an empty send (no text, no references) fires no haptic")
    func emptySendFiresNoHaptic() async throws {
        let haptics = RecordingHapticsEngine()
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: ScriptedDriver(events: []),
            messageRepository: StubMessageRepository(initial: []),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)],
            hapticsEngine: haptics
        )

        viewModel.send("   ")

        #expect(haptics.played.isEmpty)
    }
}

private enum StubError: Error { case boom }

// MARK: - Test doubles

/// Subscription streams remain open until closeStream().
private actor HangingSubscribeDriver: ChatSessionDriver {
    private let pendingSnapshot: ChatSession.LiveTurnSnapshot?
    private var continuations: [AsyncStream<ChatEvent>.Continuation] = []
    private(set) var subscribeCount: Int = 0
    private(set) var cancelInvocationCount: Int = 0

    init(pendingSnapshot: ChatSession.LiveTurnSnapshot?) {
        self.pendingSnapshot = pendingSnapshot
    }

    func send(text: String, model: LLMModel, references: [RecordReference]) async -> AsyncStream<ChatEvent> {
        let (stream, continuation) = AsyncStream<ChatEvent>.makeStream()
        continuation.finish()
        return stream
    }

    func retry(model: LLMModel) async -> AsyncStream<ChatEvent> {
        let (stream, continuation) = AsyncStream<ChatEvent>.makeStream()
        continuation.finish()
        return stream
    }

    func subscribe() async -> (snapshot: ChatSession.LiveTurnSnapshot?, stream: AsyncStream<ChatEvent>) {
        subscribeCount += 1
        let (stream, continuation) = AsyncStream<ChatEvent>.makeStream()
        continuations.append(continuation)
        return (pendingSnapshot, stream)
    }

    func cancel() async { cancelInvocationCount += 1 }

    func confirmToolCall(id: String) async {}
    func skipToolCall(id: String) async {}

    func closeStream() {
        for continuation in continuations { continuation.finish() }
        continuations.removeAll()
    }
}

/// Replays scripts into buffered streams; retry and subscribe fill them synchronously.
private actor ScriptedDriver: ChatSessionDriver {
    private let scripted: [ChatEvent]
    private let retryScripted: [ChatEvent]
    private let pendingSubscribeEvents: [ChatEvent]
    private let pendingSnapshot: ChatSession.LiveTurnSnapshot?
    private var finished = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelInvocationCount: Int = 0
    private(set) var retryInvocations: Int = 0

    init(
        events: [ChatEvent],
        retryEvents: [ChatEvent] = [],
        pendingSnapshot: ChatSession.LiveTurnSnapshot? = nil,
        pendingSubscribeEvents: [ChatEvent] = []
    ) {
        self.scripted = events
        self.retryScripted = retryEvents
        self.pendingSnapshot = pendingSnapshot
        self.pendingSubscribeEvents = pendingSubscribeEvents
    }

    func send(text: String, model: LLMModel, references: [RecordReference]) async -> AsyncStream<ChatEvent> {
        let scripted = self.scripted
        let (stream, continuation) = AsyncStream<ChatEvent>.makeStream()
        let actorRef = self
        Task {
            for event in scripted {
                continuation.yield(event)
                await Task.yield()
            }
            continuation.finish()
            await actorRef.markFinished()
        }
        return stream
    }

    func retry(model: LLMModel) async -> AsyncStream<ChatEvent> {
        retryInvocations += 1
        finished = false
        let (stream, continuation) = AsyncStream<ChatEvent>.makeStream()
        for event in retryScripted {
            continuation.yield(event)
        }
        continuation.finish()
        markFinished()
        return stream
    }

    func subscribe() async -> (snapshot: ChatSession.LiveTurnSnapshot?, stream: AsyncStream<ChatEvent>) {
        let (stream, continuation) = AsyncStream<ChatEvent>.makeStream()
        for event in pendingSubscribeEvents {
            continuation.yield(event)
        }
        continuation.finish()
        markFinished()
        return (pendingSnapshot, stream)
    }

    func cancel() async {
        cancelInvocationCount += 1
    }

    func confirmToolCall(id: String) async {}
    func skipToolCall(id: String) async {}

    func cancelCount() -> Int { cancelInvocationCount }

    private func markFinished() {
        finished = true
        let waiters = finishWaiters
        finishWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Keep the finished check and waiter registration actor-isolated to avoid
    /// losing a concurrent markFinished() signal.
    func waitUntilFinished() async throws {
        if finished { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finishWaiters.append(continuation)
        }
    }
}

private actor RecordingDriver: ChatSessionDriver {
    private(set) var sentText: [String] = []
    private(set) var sentReferences: [[RecordReference]] = []
    private(set) var retryInvocations: Int = 0
    private var sendWaiter: CheckedContinuation<Void, Never>?
    private var retryWaiter: CheckedContinuation<Void, Never>?

    var sendInvocationCount: Int { sentText.count }

    func send(text: String, model: LLMModel, references: [RecordReference]) async -> AsyncStream<ChatEvent> {
        sentText.append(text)
        sentReferences.append(references)
        sendWaiter?.resume()
        sendWaiter = nil
        let (stream, continuation) = AsyncStream<ChatEvent>.makeStream()
        continuation.finish()
        return stream
    }

    func retry(model: LLMModel) async -> AsyncStream<ChatEvent> {
        retryInvocations += 1
        retryWaiter?.resume()
        retryWaiter = nil
        let (stream, continuation) = AsyncStream<ChatEvent>.makeStream()
        continuation.finish()
        return stream
    }

    func subscribe() async -> (snapshot: ChatSession.LiveTurnSnapshot?, stream: AsyncStream<ChatEvent>) {
        let (stream, continuation) = AsyncStream<ChatEvent>.makeStream()
        continuation.finish()
        return (nil, stream)
    }

    func cancel() async {}

    private(set) var confirmedToolCallIDs: [String] = []
    private(set) var skippedToolCallIDs: [String] = []

    private var searchDecisionWaiter: CheckedContinuation<Void, Never>?

    func confirmToolCall(id: String) async {
        confirmedToolCallIDs.append(id)
        searchDecisionWaiter?.resume()
        searchDecisionWaiter = nil
    }

    func skipToolCall(id: String) async {
        skippedToolCallIDs.append(id)
        searchDecisionWaiter?.resume()
        searchDecisionWaiter = nil
    }

    func waitForSend() async {
        guard sentText.isEmpty else { return }
        await withCheckedContinuation { sendWaiter = $0 }
    }

    func waitForRetry() async {
        guard retryInvocations == 0 else { return }
        await withCheckedContinuation { retryWaiter = $0 }
    }

    func waitForSearchDecision() async {
        guard confirmedToolCallIDs.isEmpty, skippedToolCallIDs.isEmpty else { return }
        await withCheckedContinuation { searchDecisionWaiter = $0 }
    }
}

private struct FakeChatSuggestionsProvider: ChatSuggestionsProvider {
    let scripted: [SuggestedChatAction]
    func suggestions(fallback: [SuggestedChatAction]) async -> [SuggestedChatAction] { scripted }
}

private actor StubMessageRepository: MessageRepository {
    private var rows: [MessageRecord]
    private var deleteError: Error?
    private var shouldSuspendFetch = false
    private var shouldFailFetch = false
    private var fetchContinuation: CheckedContinuation<Void, Never>?
    private var fetchWaiter: CheckedContinuation<Void, Never>?

    func failNextFetch() { shouldFailFetch = true }
    func suspendNextFetch() { shouldSuspendFetch = true }
    func waitForSuspendedFetch() async {
        if fetchContinuation != nil { return }
        await withCheckedContinuation { fetchWaiter = $0 }
    }
    func resumeFetch() {
        fetchContinuation?.resume()
        fetchContinuation = nil
    }

    init(initial: [MessageRecord] = []) {
        self.rows = initial
    }

    func set(_ rows: [MessageRecord]) {
        self.rows = rows
    }

    func setDeleteError(_ error: Error?) {
        self.deleteError = error
    }

    func fetchAll(conversationId: String) async throws -> [MessageRecord] {
        if shouldFailFetch {
            shouldFailFetch = false
            throw LLMError.unauthorized
        }
        if shouldSuspendFetch {
            shouldSuspendFetch = false
            await withCheckedContinuation { continuation in
                fetchContinuation = continuation
                fetchWaiter?.resume()
                fetchWaiter = nil
            }
        }
        return rows.filter { $0.conversationId == conversationId }
    }

    func fetch(id: String) async throws -> MessageRecord? {
        rows.first(where: { $0.id == id })
    }

    func hasUserMessage(conversationId: String) async throws -> Bool {
        rows.contains { $0.conversationId == conversationId && $0.role == .user }
    }

    func save(_ record: MessageRecord) async throws {
        rows.removeAll { $0.id == record.id }
        rows.append(record)
    }

    func delete(ids: [String]) async throws {
        if let deleteError {
            throw deleteError
        }
        rows.removeAll { ids.contains($0.id) }
    }

    func deleteAll(conversationId: String) async throws {
        rows.removeAll { $0.conversationId == conversationId }
    }
}

private actor StubToolCallRepository: ToolCallRepository {
    private var rows: [ToolCallRecord] = []

    func fetchByConversation(_ conversationId: String) async throws -> [ToolCallRecord] {
        rows.filter { $0.conversationId == conversationId }
    }

    func fetchByMessage(_ messageId: String) async throws -> [ToolCallRecord] {
        rows.filter { $0.messageId == messageId }
    }

    func fetchByStatus(_ status: ToolCallStatus) async throws -> [ToolCallRecord] {
        rows.filter { $0.status == status }
    }

    func fetch(id: String) async throws -> ToolCallRecord? {
        rows.first(where: { $0.id == id })
    }

    func save(_ record: ToolCallRecord) async throws {
        rows.removeAll { $0.id == record.id }
        rows.append(record)
    }

    func updateStatus(
        id: String,
        status: ToolCallStatus,
        result: String?,
        completedAt: Date?
    ) async throws {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        var row = rows[i]
        row.status = status
        row.result = result
        row.completedAt = completedAt
        rows[i] = row
    }
}

private actor StubConversationRepository: ConversationRepository {
    private var rows: [ConversationRecord]

    init(initial: [ConversationRecord] = []) {
        self.rows = initial
    }

    func listActive() async throws -> [ConversationRecord] {
        rows.filter { $0.deletedAt == nil }
    }

    func listActiveRecent(limit: Int) async throws -> [ConversationRecord] {
        let active = rows
            .filter { $0.deletedAt == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
        return Array(active.prefix(limit))
    }

    func fetch(id: String) async throws -> ConversationRecord? {
        rows.first(where: { $0.id == id })
    }

    func save(_ record: ConversationRecord) async throws {
        rows.removeAll { $0.id == record.id }
        rows.append(record)
    }

    func softDelete(id: String, at deletedAt: Date) async throws {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        var row = rows[i]
        guard row.deletedAt == nil else { return }
        row.deletedAt = deletedAt
        row.updatedAt = deletedAt
        rows[i] = row
    }

    func hardDelete(id: String) async throws {
        rows.removeAll { $0.id == id }
    }
}

@MainActor
private final class TitleSpy {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

@MainActor
private final class MainActorCounter {
    var value: Int = 0
}

private actor StubCheckpointRepository: CompactionCheckpointRepository {
    private var rows: [CompactionCheckpointRecord] = []
    private var deleteError: Error?

    func liveCheckpoint(for conversationId: String) async throws -> CompactionCheckpointRecord? {
        rows.first(where: { $0.conversationId == conversationId && $0.isLive })
    }

    func all(for conversationId: String) async throws -> [CompactionCheckpointRecord] {
        rows.filter { $0.conversationId == conversationId }
    }

    func save(_ record: CompactionCheckpointRecord) async throws {
        rows.removeAll { $0.id == record.id }
        if record.isLive {
            for i in rows.indices where rows[i].conversationId == record.conversationId && rows[i].isLive {
                rows[i].isLive = false
            }
        }
        rows.append(record)
    }

    func delete(ids: [String]) async throws {
        if let deleteError {
            throw deleteError
        }
        rows.removeAll { ids.contains($0.id) }
    }

    func setDeleteError(_ error: Error?) {
        self.deleteError = error
    }

    func snapshotRows() -> [CompactionCheckpointRecord] { rows }

    func seed(_ records: [CompactionCheckpointRecord]) { rows = records }
}

private actor TitleSettingRepository: SettingRepository {
    private var storage: [String: String] = [:]

    func get(_ key: String) async throws -> String? { storage[key] }
    func set(_ key: String, value: String) async throws { storage[key] = value }
    func delete(_ key: String) async throws { storage.removeValue(forKey: key) }
    func all() async throws -> [String: String] { storage }
}
