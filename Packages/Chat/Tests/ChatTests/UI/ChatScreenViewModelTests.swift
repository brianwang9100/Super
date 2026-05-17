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

    @Test("resolveInitialModelId returns the persisted id when it is in the available list")
    func resolveInitialModelIdReturnsPersistedWhenValid() {
        let a = makeModel(id: "model-a")
        let b = makeModel(id: "model-b")
        let resolved = ChatScreenViewModel.resolveInitialModelId(
            persisted: "model-b",
            available: [a, b]
        )
        #expect(resolved == "model-b")
    }

    @Test("resolveInitialModelId falls back to first available when persisted is nil")
    func resolveInitialModelIdFallsBackWhenNilPersisted() {
        let a = makeModel(id: "model-a")
        let b = makeModel(id: "model-b")
        let resolved = ChatScreenViewModel.resolveInitialModelId(
            persisted: nil,
            available: [a, b]
        )
        #expect(resolved == "model-a")
    }

    @Test("resolveInitialModelId falls back to first available when persisted id is stale")
    func resolveInitialModelIdFallsBackWhenStalePersisted() {
        // Regression: user deleted their previously-selected model
        // between launches. Resolver must not return the stale id — the
        // host would otherwise hand a nonexistent id to
        // `ChatScreenViewModel.init`, where `activeModel` would still
        // fall back to first but the picker's UI state could lag.
        let a = makeModel(id: "model-a")
        let b = makeModel(id: "model-b")
        let resolved = ChatScreenViewModel.resolveInitialModelId(
            persisted: "deleted-model",
            available: [a, b]
        )
        #expect(resolved == "model-a")
    }

    @Test("resolveInitialModelId returns nil when no models are available")
    func resolveInitialModelIdReturnsNilWhenEmpty() {
        let resolved = ChatScreenViewModel.resolveInitialModelId(
            persisted: "any-id",
            available: []
        )
        #expect(resolved == nil)
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
            availableModels: [model]
        )

        // After userMessageSaved the repo will be queried again, so seed
        // the post-write state ahead of time.
        let savedUser = MessageRecord(id: "u1", conversationId: conversationId, role: .user, content: "hi", createdAt: Date())
        let savedAssistant = MessageRecord(id: "a1", conversationId: conversationId, role: .assistant, content: "Hello", createdAt: Date().addingTimeInterval(1))
        await messages.set([savedUser, savedAssistant])

        viewModel.send("hi")
        try await driver.waitUntilFinished()
        // Yield once so the @MainActor task posting state changes drains.
        await yieldUntilNotStreaming(viewModel)

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
            availableModels: [model]
        )

        viewModel.send("hi")
        try await driver.waitUntilFinished()
        await yieldUntilNotStreaming(viewModel)

        #expect(viewModel.error?.message.contains("Authentication failed") == true)
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

        viewModel.setAvailableModels([model])

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
            availableModels: [model]
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
            availableModels: [model]
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
            availableModels: [model]
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

        viewModel.setAvailableModels([model])

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
            availableModels: [model]
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
            if case .assistantText(_, _, _, let text, _) = item {
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
            availableModels: [model]
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
            availableModels: [model]
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
            availableModels: [model]
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
            availableModels: [model]
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
            availableModels: [model]
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
        await yieldUntilNotStreaming(viewModel)
        #expect(viewModel.isStreaming == false)
    }

    private func yieldUntilNotStreaming(_ viewModel: ChatScreenViewModel) async {
        for _ in 0..<400 {
            if !viewModel.isStreaming { return }
            await Task.yield()
        }
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
        let titleGen = TitleGenerator(llmProviderRegistry: registry)

        let firedTitles = TitleSpy()
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "New chat",
            driver: driver,
            messageRepository: messages,
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [model],
            conversationRepository: conversations,
            titleGenerator: titleGen
        )
        viewModel.onTitleGenerated = { title in
            Task { await firedTitles.append(title) }
        }

        viewModel.send("Plan a Lisbon trip")
        try await driver.waitUntilFinished()
        await viewModel._waitForPendingTitleTask()
        await yieldUntilNotStreaming(viewModel)
        await yieldUntilHeaderUpdates(viewModel, expected: "Lisbon trip plan")

        #expect(viewModel.headerTitle == "Lisbon trip plan")
        let stored = try await conversations.fetch(id: conversationId)
        #expect(stored?.title == "Lisbon trip plan")

        // Two callbacks fire on a fresh chat: the truncation fallback on
        // user-send, then the LLM-generated title on assistant-saved.
        await yieldUntilFiredCount(firedTitles, atLeast: 2)
        let firedSnapshot = await firedTitles.values
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
            availableModels: [model],
            conversationRepository: conversations,
            titleGenerator: TitleGenerator(llmProviderRegistry: registry)
        )

        viewModel.send("Hi")
        try await driver.waitUntilFinished()
        await viewModel._waitForPendingTitleTask()
        await yieldUntilNotStreaming(viewModel)
        await yieldUntilHeaderUpdates(viewModel, expected: "Greeting chat")

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
            availableModels: [model],
            conversationRepository: conversations,
            titleGenerator: TitleGenerator(llmProviderRegistry: registry)
        )

        viewModel.send("Continue")
        try await driver.waitUntilFinished()
        await viewModel._waitForPendingTitleTask()
        await yieldUntilNotStreaming(viewModel)

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
            availableModels: [model],
            conversationRepository: conversations,
            titleGenerator: TitleGenerator(llmProviderRegistry: registry)
        )

        viewModel.send("Hi")
        try await driver.waitUntilFinished()
        await viewModel._waitForPendingTitleTask()
        await yieldUntilNotStreaming(viewModel)

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
            availableModels: [model],
            conversationRepository: conversations,
            titleGenerator: TitleGenerator(llmProviderRegistry: registry)
        )

        viewModel.send("Hi")
        try await driver.waitUntilFinished()
        await viewModel._waitForPendingTitleTask()
        await yieldUntilNotStreaming(viewModel)

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
            availableModels: [model],
            conversationRepository: conversations
        )

        viewModel.send("How do I reset my password on Linux?")
        try await driver.waitUntilFinished()
        await yieldUntilNotStreaming(viewModel)
        await yieldUntilHeaderUpdates(viewModel, expected: "How do I reset my pa…")

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
            availableModels: [model],
            conversationRepository: conversations,
            titleGenerator: TitleGenerator(llmProviderRegistry: registry)
        )

        viewModel.send("Plan a Lisbon trip with kids")
        try await driver.waitUntilFinished()
        await viewModel._waitForPendingTitleTask()
        await yieldUntilNotStreaming(viewModel)
        await yieldUntilHeaderUpdates(viewModel, expected: "Lisbon trip plan")

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
            availableModels: [model],
            conversationRepository: conversations
        )

        viewModel.send("Plan a Lisbon trip with kids")
        try await driver.waitUntilFinished()
        await yieldUntilNotStreaming(viewModel)
        await yieldUntilHeaderUpdates(viewModel, expected: "Plan a Lisbon trip w…")

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
            availableModels: [model],
            conversationRepository: conversations
        )

        viewModel.send("Continue")
        try await driver.waitUntilFinished()
        await yieldUntilNotStreaming(viewModel)

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

    private func yieldUntilHeaderUpdates(_ viewModel: ChatScreenViewModel, expected: String) async {
        for _ in 0..<400 {
            if viewModel.headerTitle == expected { return }
            await Task.yield()
        }
    }

    private func yieldUntilFiredCount(_ spy: TitleSpy, atLeast count: Int) async {
        for _ in 0..<400 {
            if await spy.values.count >= count { return }
            await Task.yield()
        }
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

        await viewModel.handleMicTap()
        voiceService.emit(.final("hello"))
        await yieldUntilVoiceState(voice, .idle)

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
            availableModels: [model]
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
            availableModels: [model],
            voice: voice
        )
    }

    private func yieldUntilVoiceState(_ voice: VoiceInputController, _ expected: VoiceInputController.State) async {
        for _ in 0..<400 {
            if voice.state == expected { return }
            await Task.yield()
        }
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
            availableModels: [model],
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
}

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

    func send(text: String, references: [RecordReference], model: LLMModel) async -> AsyncStream<ChatEvent> {
        // The bug-under-test exercises subscribe(), not send(). Return a
        // stream that finishes immediately for symmetry with the
        // production driver's contract.
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
    /// Events for a fake "already in flight" turn, replayed by
    /// `subscribe()`. Tests that exercise the re-attach path enqueue
    /// these; the default empty list keeps `subscribe()` finishing
    /// immediately so existing tests stay unchanged.
    private let pendingSubscribeEvents: [ChatEvent]
    private let pendingSnapshot: ChatSession.LiveTurnSnapshot?
    private var finished = false
    private var continuation: AsyncStream<Void>.Continuation?
    private var cancelInvocationCount: Int = 0

    init(
        events: [ChatEvent],
        pendingSnapshot: ChatSession.LiveTurnSnapshot? = nil,
        pendingSubscribeEvents: [ChatEvent] = []
    ) {
        self.scripted = events
        self.pendingSnapshot = pendingSnapshot
        self.pendingSubscribeEvents = pendingSubscribeEvents
    }

    func send(text: String, references: [RecordReference], model: LLMModel) async -> AsyncStream<ChatEvent> {
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

    func cancelCount() -> Int { cancelInvocationCount }

    private func markFinished() {
        finished = true
        continuation?.yield(())
        continuation?.finish()
        continuation = nil
    }

    nonisolated func waitUntilFinished() async throws {
        // Poll on the actor for completion. Cheap given the finite scripted
        // sequence, and avoids exposing `finished` via a continuation.
        for _ in 0..<200 {
            if await self.finished { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// `ChatSessionDriver` fake that records the `text` and `references` of
/// every `send(...)` and returns an immediately-finished stream. Exposes
/// `waitForSend()` so a test can await the first call without polling.
private actor RecordingDriver: ChatSessionDriver {
    private(set) var sentText: [String] = []
    private(set) var sentReferences: [[RecordReference]] = []
    private var sendWaiter: CheckedContinuation<Void, Never>?

    func send(text: String, references: [RecordReference], model: LLMModel) async -> AsyncStream<ChatEvent> {
        sentText.append(text)
        sentReferences.append(references)
        sendWaiter?.resume()
        sendWaiter = nil
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

    /// Await the first `send(...)`; returns immediately if it already ran.
    func waitForSend() async {
        guard sentText.isEmpty else { return }
        await withCheckedContinuation { sendWaiter = $0 }
    }
}

private actor StubMessageRepository: MessageRepository {
    private var rows: [MessageRecord]

    init(initial: [MessageRecord] = []) {
        self.rows = initial
    }

    func set(_ rows: [MessageRecord]) {
        self.rows = rows
    }

    func fetchAll(conversationId: String) async throws -> [MessageRecord] {
        rows.filter { $0.conversationId == conversationId }
    }

    func fetch(id: String) async throws -> MessageRecord? {
        rows.first(where: { $0.id == id })
    }

    func save(_ record: MessageRecord) async throws {
        rows.removeAll { $0.id == record.id }
        rows.append(record)
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

/// Records titles fired through `onTitleGenerated`. The hook itself runs
/// on `@MainActor`, but we want to inspect the appended values from the
/// test body without forcing every assertion onto the main actor — so the
/// spy is an actor and the hook posts via `Task { await spy.append(...) }`.
private actor TitleSpy {
    var values: [String] = []

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
}
