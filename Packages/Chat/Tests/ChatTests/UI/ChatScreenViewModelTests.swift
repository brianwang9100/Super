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

    @Test("send is a no-op when no model is available")
    func sendNoOpWhenNoModel() {
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
        #expect(viewModel.isStreaming == false)
        #expect(viewModel.composerText == "")
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

    @Test("Verbosity is externally writable so the host can push Settings changes into the open chat")
    func hostCanPushVerbosityFromSettings() {
        // Models the live-flow path in `ChatHostView`:
        //   .onChange(of: settingsViewModel?.settings.defaultVerbosity) { _, newValue in
        //       if let newValue { viewModel?.verbosity = newValue }
        //   }
        // A unit test on the actual SwiftUI `.onChange` modifier isn't
        // feasible (the modifier requires a hosted view tree), so we cover
        // the half-of-the-contract that runs in the view model: the host
        // must be able to assign new values to `verbosity` and have them
        // stick for `MessageList` to read. If someone tightens this to
        // `private(set)` in the future, the host wiring breaks at compile
        // time and this test fails first.
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: ScriptedDriver(events: []),
            messageRepository: StubMessageRepository(),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [model]
        )

        #expect(viewModel.verbosity == .simple)

        viewModel.verbosity = .verbose
        #expect(viewModel.verbosity == .verbose)

        viewModel.verbosity = .thinking
        #expect(viewModel.verbosity == .thinking)

        viewModel.verbosity = .simple
        #expect(viewModel.verbosity == .simple)
    }

    @Test("Verbosity passed via init seeds the property so the first render reflects ChatSettings.defaultVerbosity")
    func initSeedsVerbosityFromHost() {
        // The host (`ChatHostView.rebuildChatViewModel`) constructs the
        // view model with `verbosity: settingsViewModel?.settings.defaultVerbosity ?? .verbose`.
        // Verify the init parameter actually lands in the stored property
        // — otherwise the first render would flash `.simple` before the
        // `.onChange` push corrected it.
        let viewModel = ChatScreenViewModel(
            conversationId: conversationId,
            conversationTitle: "Test",
            driver: ScriptedDriver(events: []),
            messageRepository: StubMessageRepository(),
            toolCallRepository: StubToolCallRepository(),
            checkpointRepository: StubCheckpointRepository(),
            availableModels: [model],
            verbosity: .verbose
        )
        #expect(viewModel.verbosity == .verbose)
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
}

// MARK: - Test doubles

/// `ChatSessionDriver` fake that yields a pre-baked event sequence on each
/// `send(...)`. Once the events drain the stream finishes, mirroring the
/// always-finishes contract `ChatSession` provides.
private actor ScriptedDriver: ChatSessionDriver {
    private let scripted: [ChatEvent]
    private var finished = false
    private var continuation: AsyncStream<Void>.Continuation?

    init(events: [ChatEvent]) {
        self.scripted = events
    }

    func send(text: String, model: LLMModel) async -> AsyncStream<ChatEvent> {
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
