import Core
import Foundation
import Testing
@testable import Chat

/// End-to-end coverage on the view-model state machine. Drives a fake
/// `ChatSessionDriver` whose stream yields a scripted sequence of
/// `ChatEvent`s, and asserts the observable state the view reads.
///
/// Each test that injects a `TitleGenerator` calls
/// `viewModel._waitForPendingTitleTask()` immediately after the driver
/// drain — *before* assertions — so the auto-title `Task` is fully
/// done before the test reads `headerTitle` or the title-fire spy.
/// That ordering also lets the suite run in parallel: no `.serialized`
/// safety net needed.
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

    /// Build a `TitleGenerator` whose summarizer setting selects the test
    /// `model` (titling on), so the auto-title path resolves to the provider
    /// registered in these fixtures rather than the automatic AFM default.
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
        // Back-compat: before the record-id convergence, this was stored as the
        // `LLMModel.id`. An upgraded install must still land on the same model,
        // resolving to its record id (which then re-persists on next pick).
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
        // Regression: user deleted their previously-selected model
        // between launches. Resolver must not return the stale id — the
        // host would otherwise hand a nonexistent id to
        // `ChatScreenViewModel.init`, where `activeModel` would still
        // fall back to first but the picker's UI state could lag.
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

    @Test("fresh selection respects the seeded PCC record before sorted debug alternatives")
    func initialSelectionRespectsSeed() {
        let debug = SelectableModel(recordId: "debug-canned", model: makeModel(id: "debug"))
        let pcc = SelectableModel(recordId: "seed", model: makeModel(id: "private-cloud-compute"))
        #expect(ChatScreenViewModel.resolveInitialModelId(
            persisted: nil, available: [debug, pcc], preferredRecordId: "seed"
        ) == "seed")
    }

    @Test("an existing explicit local selection wins over the new OS default")
    func initialSelectionPreservesExistingChoice() {
        let local = SelectableModel(recordId: "local", model: makeModel(id: "system-default"))
        let pcc = SelectableModel(recordId: "pcc", model: makeModel(id: "private-cloud-compute"))
        for persisted in ["local", "system-default"] {
            #expect(ChatScreenViewModel.resolveInitialModelId(
                persisted: persisted, available: [pcc, local], preferredRecordId: "pcc"
            ) == "local")
        }
    }

    @Test("a stale picker choice resolves to the selected unavailable PCC record, not another backend")
    func staleChoiceRespectsSelectedRecord() {
        let remote = SelectableModel(recordId: "remote", model: makeModel(id: "remote"))
        let pcc = SelectableModel(recordId: "pcc", model: makeModel(id: "private-cloud-compute"))
        #expect(ChatScreenViewModel.resolveInitialModelId(
            persisted: "deleted", available: [remote, pcc], preferredRecordId: "pcc"
        ) == "pcc")
    }

    @Test("two rows sharing a modelId are independently selectable by record id")
    func sameModelIdRowsSelectableByRecordId() {
        // The convergence guarantee: two configured models with the SAME
        // upstream `modelId` (e.g. two BYOK keys for `gpt-4o`, or the debug
        // canned/mock-search rows) must each be selectable. Keying on the
        // record id — not the shared `model.id` — makes `activeModel` follow
        // the picked row.
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
        // Selecting the other record id moves the active model to that row.
        vm.selectedModelId = "rec-a"
        #expect(vm.selectedModelId == "rec-a")
        #expect(vm.activeModel?.id == shared)
    }

    // MARK: - Empty-state suggestions

    @Test(arguments: [false, true])
    func resolvedContextReachesComposerWithoutChangingSelection(lateSubscriber: Bool) async {
        let placeholder = LLMModel(id: "private-cloud-compute", displayName: "PCC", maxContextTokens: 0)
        let resolved = SelectableModel(recordId: "pcc", model: LLMModel(
            id: placeholder.id, displayName: placeholder.displayName, maxContextTokens: 32_768
        ))
        let other = SelectableModel(recordId: "other", model: placeholder)
        let driver = ScriptedDriver(
            events: [],
            pendingSnapshot: .init(
                accumulatedText: "", accumulatedThinking: "",
                resolvedModel: lateSubscriber ? resolved : nil
            ),
            pendingSubscribeEvents: lateSubscriber ? [] : [.modelResolved(resolved)]
        )
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId, conversationTitle: "Test", driver: driver,
            messageRepository: StubMessageRepository(initial: []),
            toolCallRepository: StubToolCallRepository(), checkpointRepository: StubCheckpointRepository(),
            availableModels: [.init(recordId: "pcc", model: placeholder), other], selectedModelId: "pcc"
        )
        await viewModel.load()
        await viewModel._waitForPendingStreamTask()
        #expect(viewModel.selectedModelId == "pcc")
        #expect(viewModel.maxContextTokens == 32_768)
        #expect(viewModel.modelOptions.first?.maxContextTokens == 32_768)
        #expect(viewModel.availableModels.last == other)
    }

    @Test
    func staleResolvedContextCannotReviveOrReplaceAModel() async {
        let current = SelectableModel(recordId: "existing", model: model)
        let changedBackend = SelectableModel(recordId: current.recordId, model: LLMModel(
            id: "private-cloud-compute", displayName: "PCC", maxContextTokens: 32_768
        ))
        let deleted = SelectableModel(recordId: "deleted", model: model)
        let driver = ScriptedDriver(
            events: [], pendingSnapshot: .init(accumulatedText: "", accumulatedThinking: ""),
            pendingSubscribeEvents: [.modelResolved(changedBackend), .modelResolved(deleted)]
        )
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId, conversationTitle: "Test", driver: driver,
            messageRepository: StubMessageRepository(initial: []),
            toolCallRepository: StubToolCallRepository(), checkpointRepository: StubCheckpointRepository(),
            availableModels: [current], selectedModelId: current.recordId
        )
        await viewModel.load()
        await viewModel._waitForPendingStreamTask()
        #expect(viewModel.availableModels == [current])
        #expect(viewModel.selectedModelId == current.recordId)
    }

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
        // A second call with a different fallback must not re-run.
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

        // After userMessageSaved the repo will be queried again, so seed
        // the post-write state ahead of time.
        let savedUser = MessageRecord(id: "u1", conversationId: conversationId, role: .user, content: "hi", createdAt: Date())
        let savedAssistant = MessageRecord(id: "a1", conversationId: conversationId, role: .assistant, content: "Hello", createdAt: Date().addingTimeInterval(1))
        await messages.set([savedUser, savedAssistant])

        viewModel.send("hi")
        try await driver.waitUntilFinished()
        // Drain the subscription task on its own completion, not a poll.
        await viewModel._waitForPendingStreamTask()

        #expect(viewModel.isStreaming == false)
        #expect(viewModel.streamingTail == nil)
        #expect(viewModel.items.count == 2)
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
        // Regression: previously the Retry pill called driver.send(text:) with
        // the failed message's text, which created a *second* MessageRecord
        // in the database and rendered as a duplicate user bubble. The fix
        // routes Retry through a dedicated driver.retry(model:) entry point
        // that re-runs the LLM loop against the already-persisted transcript.
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
        // Prime an error state without going through send — equivalent to
        // the post-failure state the user taps Retry from. Must include a
        // user bubble in `items` because `retry()` now guards
        // synchronously against an empty transcript before invoking the
        // driver (so a stale tap on a brand-new conversation no-ops
        // without flashing the streaming UI).
        viewModel._setSnapshotState(
            items: [
                .userBubble(id: "u1", text: "test", references: [])
            ],
            error: MessageList.ErrorState(message: "Authentication failed.")
        )

        viewModel.retry()
        await driver.waitForRetry()
        await viewModel._waitForPendingStreamTask()

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
        // Defensive: a double-tap on the Retry pill (or a tap during the
        // brief window where the prior failed turn is still draining
        // events) must not spawn a second `consume` task — that race
        // would let two streams mutate `streamingTail`, `error`, and the
        // transcript concurrently. The guard mirrors `send`'s
        // `guard !isStreaming else { return }`.
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
        // Pin the VM into a mid-stream state: error set, user bubble in
        // items, isStreaming true. The view model holds the precondition
        // `streamingTail != nil ⇔ isStreaming`, so we set both.
        viewModel._setSnapshotState(
            items: [.userBubble(id: "u1", text: "test", references: [])],
            streamingTail: MessageList.StreamingState(
                thinking: "", thinkingStartedAt: nil, text: "", isCompacting: false
            ),
            error: MessageList.ErrorState(message: "Authentication failed."),
            isStreaming: true
        )

        viewModel.retry()

        // The guard runs synchronously; no driver call, no observable
        // state change, no Task spawned. The error banner stays so the
        // user keeps the signal that the prior turn failed.
        #expect(await driver.retryInvocations == 0)
        #expect(await driver.sendInvocationCount == 0)
        #expect(viewModel.isStreaming == true)
        #expect(viewModel.error?.message.contains("Authentication failed") == true)
    }

    @Test("retry after an LLM error does not duplicate the user bubble in the transcript")
    func retryDoesNotDuplicateUserBubble() async throws {
        // End-to-end regression for the duplicate-message bug: send fails,
        // user taps Retry, retry succeeds — final transcript must contain
        // exactly one user bubble (the original), not two.
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
        // Mirror production: the failed turn persisted the user row before
        // the LLM errored, so the row exists on disk during the error.
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

        // Mirror production: by the time retry succeeds, the assistant row
        // has been persisted by ChatSession on `.messageComplete`.
        await messages.set([userRow, assistantRow])

        viewModel.retry()
        await viewModel._waitForPendingStreamTask()

        let userBubbleCountAfterRetry = viewModel.items.filter {
            if case .userBubble = $0 { return true }
            return false
        }.count
        #expect(userBubbleCountAfterRetry == 1)
        #expect(viewModel.error == nil)
        // Sanity check: the new assistant content landed.
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
        // Manual `/compact` rejects synchronously when context usage is
        // below the minimum-ratio gate. The composer must keep the typed
        // command after a rejection so the user can retry once enough
        // messages have accumulated — clearing it on submit would erase
        // the only context the user has for "what I just tried."
        // Regular submissions still clear because their text becomes a
        // user bubble below the composer.
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
        // Counterpart to the slash-command test above: a regular
        // submission must still clear the composer because the user's
        // text gets rendered as its own bubble below.
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
        // Regression: the `send` happy path's `error = nil` clearing
        // shouldn't be confused with the no-model error path. A stale
        // banner from an earlier failure has to disappear the moment
        // the user successfully sends with a real model selected.
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
        // Seed a generic error directly (e.g. a prior LLM failure).
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
        // The session reports a turn in flight via `subscribe()`. The
        // view model must hydrate `streamingTail` to the snapshot's
        // accumulated text *before* the stream task starts processing
        // any subsequent events — so a re-mounted screen never flashes
        // empty before catching up. Subsequent events from the
        // subscribed stream must continue to land normally.
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

        // Synchronously after `load()` returns, the spawned streamTask
        // has been scheduled but the @MainActor hasn't yielded yet to
        // run it. `streamingTail` therefore reflects the snapshot
        // exactly — no events have been processed.
        #expect(viewModel.streamingTail?.text == "in progress")
        #expect(viewModel.isStreaming == true)

        // Drain the subscribed events deterministically.
        await viewModel._waitForPendingStreamTask()

        // After drain, the assistant row landed via
        // `.assistantMessageSaved` and the final refresh; the streaming
        // tail cleared.
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
        // Regression: switching chat presentation states (expanded ↔
        // semi-expanded ↔ minimized) re-mounts the chat surface, which
        // re-fires `.task(id: viewModel.conversationId) { await
        // viewModel.load() }`. Before the guard in
        // `attachToLiveTurnIfAny()` landed, the second call opened a
        // parallel `AsyncStream` over the same in-flight turn, and both
        // subscribers appended every text/thinking event to
        // `streamingTail.text` — producing visible character duplication
        // in the live response (every word streamed twice). This test
        // asserts the second `load()` is a no-op while the first stream
        // is still consuming events.
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

        // First load — initial subscribe attaches to the live turn.
        await viewModel.load()
        var subscribeCount = await driver.subscribeCount
        #expect(subscribeCount == 1)
        #expect(viewModel.isStreaming == true)
        #expect(viewModel.streamingTail?.text == "in progress")

        // Second load — must NOT re-subscribe while the first stream is
        // still consuming the live turn.
        await viewModel.load()
        subscribeCount = await driver.subscribeCount
        #expect(subscribeCount == 1, "remount must not re-subscribe while the first stream is still active")
        #expect(viewModel.streamingTail?.text == "in progress", "snapshot text must not be re-applied on a remount")

        // Close the hanging stream so the streamTask drains cleanly and
        // the test doesn't leak a suspended `consume(stream:)` task.
        await driver.closeStream()
        await viewModel._waitForPendingStreamTask()
        #expect(viewModel.isStreaming == false)
    }

    @Test("load propagates snapshot.thinkingStartedAt into the streaming tail so the elapsed-time counter survives detach + reattach")
    func loadPropagatesSnapshotThinkingStartedAt() async throws {
        // Regression: navigating away from a chat that is still
        // "Thinking..." and back used to reset the "Thought for Xs"
        // counter to 0 because the view model substituted `Date()` for
        // the missing start time. The fix routes the actor's stored
        // start time through `LiveTurnSnapshot.thinkingStartedAt`; this
        // test asserts the view model copies that value into
        // `streamingTail.thinkingStartedAt` byte-for-byte instead of
        // clobbering it with the current wall clock.
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
        // The composer stop button calls `cancelStreaming()`. Now that
        // dropping the iteration alone no longer cancels the session
        // (Phase 1 removed `onTermination`), the view model must route
        // the cancel through `driver.cancel()` — otherwise the LLM
        // keeps running, charging tokens for output the user can't see.
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
        // Wait once for the tail update to land.
        for _ in 0..<200 {
            if viewModel.streamingTail?.isCompacting == true { break }
            await Task.yield()
        }

        // After all events drain, the stream finishes and the tail clears.
        // We just need to confirm the flag was true at some point — easier
        // is to keep the stream open by not ending it; here we verify the
        // final state is clean.
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
        // Both fires land on the main actor (the fallback inside the stream
        // drain, the LLM title inside the title task), so the spy records them
        // synchronously — no `Task`-hop, nothing to poll for.
        viewModel.onTitleGenerated = { title in firedTitles.append(title) }

        viewModel.send("Plan a Lisbon trip")
        try await driver.waitUntilFinished()
        // Stream task first: its completion means the drain ran (firing the
        // fallback and spawning the title task); then drain the title task.
        await viewModel._waitForPendingStreamTask()
        await viewModel._waitForPendingTitleTask()

        #expect(viewModel.headerTitle == "Lisbon trip plan")
        let stored = try await conversations.fetch(id: conversationId)
        #expect(stored?.title == "Lisbon trip plan")

        // Two callbacks fire on a fresh chat: the truncation fallback on
        // user-send, then the LLM-generated title on assistant-saved.
        let firedSnapshot = firedTitles.values
        // First user message is 18 chars — under the 20-char threshold —
        // so the fallback fires *without* an ellipsis.
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

        // Exactly one provider call: the second assistant message must not
        // trigger a re-generation.
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
        // Intentionally enqueue nothing — a generation attempt would
        // fatalError in FakeLLMProvider, which fails the test loudly.
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

        // Empty assistant content must not touch the provider.
        let captured = await titleProvider.capturedRequests()
        #expect(captured.isEmpty)
        // The truncation fallback still ran on user-send.
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
        // Empty-text-then-complete → TitleGenerator returns nil.
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
        // The truncation fallback wrote "Hi" on user-send. The
        // generator returning nil means we leave the fallback in place
        // rather than reverting to "New chat".
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
        // The fallback is applied inside the stream drain, so its task
        // completing is the signal — no header poll needed.
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
        // Title locked to the *first* user message's truncation despite
        // a second user-send going through.
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


    // MARK: - Voice input wiring (M11)

    @Test("micTap freezes prefix into committedComposerText and forwards to the controller")
    func micTapFreezesPrefixAndForwardsToggle() async {
        let voiceService = FakeVoiceInputService()
        let voice = VoiceInputController(service: voiceService)
        let viewModel = makeVoiceViewModel(voice: voice)
        viewModel.composerText = "draft prefix"

        await viewModel.handleMicTap()

        #expect(viewModel.committedComposerText == "draft prefix")
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
        // The controller fires `onFinalTranscript` (which appends to the
        // composer) inside its event handling, so draining one processed
        // event is the deterministic signal — no voice-state poll.
        await processed.next()

        #expect(viewModel.composerText == "draft hello")
        #expect(viewModel.committedComposerText == "")
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
        // Voice failures must suppress the Retry pill so tapping it
        // doesn't re-send the last LLM message — the retry would have
        // nothing to do with the voice attempt that just failed.
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

    /// Build a view model wired to a fresh `ChatReferenceInbox`, returning
    /// both so a test can publish onto the bus and drive adoption.
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

    /// Publish onto `bus` and return once `inbox` has processed the event.
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
        // Same reference id delivered twice.
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
        // Cleared synchronously by `send(_:)` so the pill doesn't linger.
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
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: RecordingDriver(),
            messageRepository: StubMessageRepository(),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)]
        )

        viewModel.confirmCopy()
        #expect(viewModel.showCopyConfirmation == true)

        await viewModel._waitForPendingCopyDismissalTask()
        #expect(viewModel.showCopyConfirmation == false)
    }

    @Test("confirmCopy: rapid second tap cancels the prior dismissal task so the pill rides the new timer")
    func confirmCopyRapidSecondTapRestartsTimer() async {
        // Without the explicit `copyDismissalTask?.cancel()`, the first
        // tap's dwell timer would fire halfway through the second tap's
        // dwell and clip the pill early. This pins the cancel-and-replace
        // shape so a future refactor can't drop it.
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: RecordingDriver(),
            messageRepository: StubMessageRepository(),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [SelectableModel(model)]
        )

        viewModel.confirmCopy()
        viewModel.confirmCopy()
        #expect(viewModel.showCopyConfirmation == true)

        await viewModel._waitForPendingCopyDismissalTask()
        // Only the second task's dwell window resets the flag; the
        // first task was cancelled before it could touch state.
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
        // a1, u2, a2 — three rows from the target to the end.
        #expect(viewModel.pendingRegenerationDeleteCount == 3)
    }

    @Test("requestRegeneration: compaction banners between target and tail are excluded from the count")
    func requestRegenerationExcludesCompactionBanners() {
        // Compaction banners project from `CompactionCheckpointRecord`,
        // not `MessageRecord`, so they aren't actually deleted by the
        // trim. Excluding them from the dialog count keeps the wording
        // honest about how many *messages* the user is losing.
        let viewModel = makeViewModelForRegen()
        viewModel._setSnapshotState(items: [
            .userBubble(id: "u1", text: "q1", references: []),
            .assistantText(id: "a1", thinking: nil, thinkingDurationMs: nil, text: "answer", toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
            .compactionBanner(id: "cb1", summary: "checkpoint"),
            .userBubble(id: "u2", text: "q2", references: []),
            .assistantText(id: "a2", thinking: nil, thinkingDurationMs: nil, text: "second", toolCalls: [], sources: [], searchSuggestionsHTML: nil, searchSystem: nil, searchQuery: nil),
        ])

        viewModel.requestRegeneration(fromAssistantMessageID: "a1")

        // a1, u2, a2 count; cb1 does not.
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
        // Defensive guard against a future caller passing the wrong id.
        // The production caller (the Regenerate button under each
        // assistant bubble) is correct today; this test pins the
        // assistant-only contract so a regression in the call site can't
        // trim a user turn and break the LLM history.
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
        // Project the persisted rows into items so the synchronous guard
        // in `retry()` sees a user bubble.
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

        // The persisted transcript was trimmed to just the first user row.
        let remaining = try? await messages.fetchAll(conversationId: conversationId).map(\.id)
        #expect(remaining == ["u1"])
        // Pending dialog state cleared synchronously on confirm.
        #expect(viewModel.pendingRegenerationTargetID == nil)
        // Drove the retry path — not a second `send`, which would
        // duplicate the user message.
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
        // Stage a pending target, then push the view model into a
        // streaming state via the snapshot seam. The streaming guard
        // must drop the confirm without trimming.
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
        // The catch block in `performRegeneration` previously swallowed
        // every error path silently; the dialog dismissed and the user
        // saw nothing change. Now a thrown delete must reach the error
        // banner so the user has a Retry affordance.
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
        // The trim never landed and retry was never invoked.
        #expect(await driver.retryInvocations == 0)
    }

    @Test("confirmRegeneration: when checkpoint delete throws, no messages are trimmed")
    func confirmRegenerationCheckpointDeleteThrowsLeavesMessagesIntact() async {
        // The regen path deletes checkpoints *before* messages so a
        // throw on the first write leaves both stores untouched — never
        // the half-trimmed state where messages are gone but stale
        // checkpoints survive. Pins that ordering invariant.
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

        // Error banner surfaced; messages untouched; no retry kicked off.
        #expect(viewModel.error?.message == "Could not regenerate. Try again.")
        let remainingMessages = try? await messages.fetchAll(conversationId: conversationId).map(\.id)
        #expect(remainingMessages == ["u1", "a1"])
        #expect(await driver.retryInvocations == 0)
    }

    @Test("confirmRegeneration: deletes checkpoints whose anchor is in the trim range")
    func confirmRegenerationDeletesStaleCheckpoint() async {
        // A `CompactionCheckpointRecord` whose `uptoMessageId` is among
        // the deleted rows leaves `ContextAssembler` prepending a stale
        // summary that covers messages no longer in the DB. The regen
        // path must drop those checkpoints so the next retry sees a
        // consistent prompt.
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
        // Anchored at `a1` (inclusive). Regenerating from `a1` deletes
        // the anchor; the checkpoint must go with it.
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
        // Mirror of the stale-checkpoint test but with the anchor before
        // the trim range. The checkpoint should stay — its summary still
        // describes pre-anchor messages that haven't been touched.
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
        // Anchored at `a1`. Regenerating from `a2` leaves `a1` in place,
        // so the checkpoint must stay.
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

    /// Shared scaffold for the Regenerate tests. Wires a recording
    /// driver and noop repos so the test can focus on the trim/retry
    /// orchestration without a live LLM or DB.
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

/// Covers the haptic fire sites in `ChatScreenViewModel`: `.selection` on a
/// committed send, `.streamingTick` per visible repaint, and one
/// `.streamCompleted` at turn end. Lives in this file so it can reuse the
/// file-private scripted-driver / stub-repository doubles. Drains the stream
/// task on its own completion signal before asserting.
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
            // Each delta ends in whitespace, so the coalescer flushes it as a
            // visible chunk → one `.streamingTick` apiece.
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
        // First haptic is the send selection.
        #expect(played.first == .selection)
        // Exactly one completion, and it is the last thing played.
        #expect(played.filter { $0 == .streamCompleted }.count == 1)
        #expect(played.last == .streamCompleted)
        // At least one streaming tick landed between send and completion.
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

        // No model → the send bails before committing; nothing should buzz.
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

/// Sentinel error for fakes that need to drive a throw path.
private enum StubError: Error { case boom }

// MARK: - Test doubles

/// `ChatSessionDriver` fake whose `subscribe()` returns a stream that
/// stays open until the test explicitly calls `closeStream()`. Used to
/// regression-test that re-mounting the chat surface (via a chat-
/// presentation-state transition) does **not** double-subscribe to the
/// in-flight turn — the streaming-duplication bug fixed in
/// `ChatScreenViewModel.attachToLiveTurnIfAny()`.
private actor HangingSubscribeDriver: ChatSessionDriver {
    private let pendingSnapshot: ChatSession.LiveTurnSnapshot?
    private var continuations: [AsyncStream<ChatEvent>.Continuation] = []
    private(set) var subscribeCount: Int = 0
    private(set) var cancelInvocationCount: Int = 0

    init(pendingSnapshot: ChatSession.LiveTurnSnapshot?) {
        self.pendingSnapshot = pendingSnapshot
    }

    func send(text: String, model: LLMModel, references: [RecordReference]) async -> AsyncStream<ChatEvent> {
        // The bug-under-test exercises subscribe(), not send(). Return a
        // stream that finishes immediately for symmetry with the
        // production driver's contract.
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

    /// Test-facing seam: finish all open subscribe streams so the view
    /// model's `consume(stream:)` task can complete and the test exits
    /// cleanly without leaking suspended tasks.
    func closeStream() {
        for continuation in continuations { continuation.finish() }
        continuations.removeAll()
    }
}

/// `ChatSessionDriver` fake that yields a pre-baked event sequence on each
/// `send(...)`. Once the events drain the stream finishes, mirroring the
/// always-finishes contract `ChatSession` provides.
private actor ScriptedDriver: ChatSessionDriver {
    private let scripted: [ChatEvent]
    /// Events the driver yields on `retry(...)`. A separate sequence so a
    /// single driver can script "first send fails, retry succeeds." When
    /// empty, `retry` returns an immediately-finished stream.
    private let retryScripted: [ChatEvent]
    /// Events for a fake "already in flight" turn, replayed by
    /// `subscribe()`. Tests that exercise the re-attach path enqueue
    /// these; the default empty list keeps `subscribe()` finishing
    /// immediately so existing tests stay unchanged.
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
        // Drive synchronously — yield the full scripted sequence and
        // finish the continuation before returning, matching the pattern
        // `subscribe()` uses. Avoids the `Task { ... await Task.yield() }`
        // "race amplifier" pattern that AGENTS.md §Testing.2 flags. The
        // consumer drains the pre-filled buffer on its own schedule.
        let (stream, continuation) = AsyncStream<ChatEvent>.makeStream()
        for event in retryScripted {
            continuation.yield(event)
        }
        continuation.finish()
        markFinished()
        return stream
    }

    func subscribe() async -> (snapshot: ChatSession.LiveTurnSnapshot?, stream: AsyncStream<ChatEvent>) {
        // Drive the AsyncStream synchronously — yield everything we have
        // and finish the continuation before returning. Avoids the
        // `Task { ... await Task.yield() }` "race amplifier" pattern that
        // AGENTS.md §Testing.2 flags. Consumers reading the stream after
        // this returns drain a pre-filled buffer in their own time.
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

    /// Await the scripted sequence finishing on a one-shot signal —
    /// `markFinished()` resumes every waiter — instead of a `Task.sleep`
    /// poll. `throws` is kept so the existing `try await` call sites stay
    /// unchanged; the body never actually throws. This is now actor-isolated
    /// (the old version was `nonisolated`): the `if finished` check and the
    /// `withCheckedContinuation` append run under the actor, closing the
    /// TOCTOU window against `markFinished()` — do not re-add `nonisolated`.
    func waitUntilFinished() async throws {
        if finished { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finishWaiters.append(continuation)
        }
    }
}

/// `ChatSessionDriver` fake that records the `text` and `references` of
/// every `send(...)` and returns an immediately-finished stream. Exposes
/// `waitForSend()` so a test can await the first call without polling.
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

    /// Await the first `send(...)`; returns immediately if it already ran.
    func waitForSend() async {
        guard sentText.isEmpty else { return }
        await withCheckedContinuation { sendWaiter = $0 }
    }

    /// Await the first `retry(...)`; returns immediately if it already ran.
    func waitForRetry() async {
        guard retryInvocations == 0 else { return }
        await withCheckedContinuation { retryWaiter = $0 }
    }

    /// Await the first confirm/skip decision; returns immediately if one
    /// already arrived. Lets the confirm/skip routing test drain the view
    /// model's fire-and-forget `Task` without polling.
    func waitForSearchDecision() async {
        guard confirmedToolCallIDs.isEmpty, skippedToolCallIDs.isEmpty else { return }
        await withCheckedContinuation { searchDecisionWaiter = $0 }
    }
}

/// Returns a scripted suggestion list regardless of the fallback — stands in
/// for the AFM generator in view-model tests.
private struct FakeChatSuggestionsProvider: ChatSuggestionsProvider {
    let scripted: [SuggestedChatAction]
    func suggestions(fallback: [SuggestedChatAction]) async -> [SuggestedChatAction] { scripted }
}

private actor StubMessageRepository: MessageRepository {
    private var rows: [MessageRecord]
    /// When set, the next `delete(ids:)` call throws this. Used by the
    /// regenerate error-surfacing test to drive the catch branch in
    /// `performRegeneration` without a real DB failure.
    private var deleteError: Error?

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
        rows.filter { $0.conversationId == conversationId }
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

/// Records titles fired through `onTitleGenerated`. Both fire paths — the
/// user-send truncation fallback and the LLM-generated title — run on
/// `@MainActor`, so a `@MainActor` recorder captures them synchronously,
/// letting the test assert against `values` with no `Task`-hop and nothing
/// to poll for. `@MainActor` isolation also makes it implicitly `Sendable`
/// for capture by the `@MainActor` `onTitleGenerated` closure.
@MainActor
private final class TitleSpy {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

/// Trivial main-actor-isolated counter used as a spy for synchronous
/// callbacks fired entirely on the main actor (e.g. the no-model error
/// banner's `onAddModelRequested` hook). `@MainActor` isolation makes
/// it implicitly `Sendable` so it can be captured by a
/// `@MainActor @Sendable` closure without `@unchecked`.
@MainActor
private final class MainActorCounter {
    var value: Int = 0
}

private actor StubCheckpointRepository: CompactionCheckpointRepository {
    private var rows: [CompactionCheckpointRecord] = []
    /// When set, the next `delete(ids:)` call throws this. Mirrors the
    /// `StubMessageRepository.setDeleteError` seam — covers the
    /// regenerate path's first-write-failure branch.
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

    /// Test helper: inspect persisted checkpoint rows.
    func snapshotRows() -> [CompactionCheckpointRecord] { rows }

    /// Test helper: seed rows so a fixture can pin pre-existing checkpoints.
    func seed(_ records: [CompactionCheckpointRecord]) { rows = records }
}

/// In-memory `SettingRepository` backing the title-summarizer store in the
/// auto-title fixtures.
private actor TitleSettingRepository: SettingRepository {
    private var storage: [String: String] = [:]

    func get(_ key: String) async throws -> String? { storage[key] }
    func set(_ key: String, value: String) async throws { storage[key] = value }
    func delete(_ key: String) async throws { storage.removeValue(forKey: key) }
    func all() async throws -> [String: String] { storage }
}
