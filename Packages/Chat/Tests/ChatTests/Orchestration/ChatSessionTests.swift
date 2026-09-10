import Core
import Foundation
import Testing

@testable import Chat

@Suite("ChatSession")
struct ChatSessionTests {

    private struct Setup {
        let database: ChatDatabase
        let messageRepo: GRDBMessageRepository
        let toolCallRepo: GRDBToolCallRepository
        let conversationRepo: GRDBConversationRepository
        let llmRegistry: LLMProviderRegistry
        let toolRegistry: ToolRegistry
        let clock: FixedClock
        let idGen: DeterministicIDGenerator
        let provider: FakeLLMProvider
        let conversation: ConversationRecord
        let model: LLMModel
        let session: ChatSession
    }

    private func makeSetup(
        scripts: [[LLMStreamEvent]] = [],
        registerProvider: Bool = true
    ) async throws -> Setup {
        let database = try ChatDatabase.makeInMemory()
        let conversationRepo = GRDBConversationRepository(database: database)
        let messageRepo = GRDBMessageRepository(database: database)
        let toolCallRepo = GRDBToolCallRepository(database: database)
        let checkpointRepo = GRDBCompactionCheckpointRepository(database: database)
        let clock = OrchestrationFixtures.defaultClock()
        let idGen = DeterministicIDGenerator(prefix: "id-", start: 0)

        let conversation = try await OrchestrationFixtures.seedConversation(in: database, clock: clock)

        let model = OrchestrationFixtures.defaultModel()
        let provider = FakeLLMProvider(model: model)
        for script in scripts { await provider.enqueue(script) }

        let llmRegistry = LLMProviderRegistry()
        if registerProvider { await llmRegistry.register(provider) }

        let toolRegistry = ToolRegistry()
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

        return Setup(
            database: database,
            messageRepo: messageRepo,
            toolCallRepo: toolCallRepo,
            conversationRepo: conversationRepo,
            llmRegistry: llmRegistry,
            toolRegistry: toolRegistry,
            clock: clock,
            idGen: idGen,
            provider: provider,
            conversation: conversation,
            model: model,
            session: session
        )
    }

    private func collect(_ stream: AsyncStream<ChatEvent>) async -> [ChatEvent] {
        var events: [ChatEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test func userMessageIsPersistedBeforeAnyAssistantWrite() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "Hi"),
                .messageComplete(usage: TokenUsage(inputTokens: 5, outputTokens: 1)),
            ],
        ])
        let stream = await setup.session.send(text: "Hello", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        guard case .userMessageSaved(let userRecord) = events.first else {
            Issue.record("expected first event to be .userMessageSaved, got \(String(describing: events.first))")
            return
        }
        #expect(userRecord.role == .user)
        #expect(userRecord.content == "Hello")
        #expect(userRecord.id == "id-1")

        let storedUser = try await setup.messageRepo.fetch(id: userRecord.id)
        #expect(storedUser != nil)
    }

    @Test func userMessageReferencesPersistAsAttachmentsOnTheSavedRow() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "ok"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 1)),
            ],
        ])
        let reference = RecordReference(
            appletID: "bible", kind: "verseRange", sourceID: "WEB/JHN/3/16",
            displayLabel: "John 3:16 (WEB)", citation: "John 3:16 (WEB)",
            snapshot: "For God so loved the world...", id: "ref-1"
        )
        let stream = await setup.session.send(
            text: "What does this teach?", model: setup.model, references: [reference]
        )
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let stored = try await setup.messageRepo.fetch(id: "id-1")
        #expect(stored?.content == "What does this teach?")
        #expect(stored?.attachments?.references == [reference])
    }

    @Test func userMessageWithoutReferencesLeavesAttachmentsColumnNil() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
        ])
        let stream = await setup.session.send(text: "Hi", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let stored = try await setup.messageRepo.fetch(id: "id-1")
        #expect(stored?.attachmentsJSON == nil)
        #expect(stored?.attachments == nil)
    }

    @Test func streamingBuffersStayOutOfDatabaseUntilCompletedAssistantIsPublished() async throws {
        let setup = try await makeSetup(registerProvider: false)
        let provider = PausableLLMProvider(model: setup.model)
        await setup.llmRegistry.register(provider)
        let stream = await setup.session.send(text: "Hi", model: setup.model)
        var iterator = stream.makeAsyncIterator()
        var events: [ChatEvent] = []
        if let first = await iterator.next() { events.append(first) }

        let deltas: [(LLMStreamEvent, ChatEvent)] = [
            (.thinkingDelta(index: 0, text: "Reasoning "), .thinkingDelta("Reasoning ")),
            (.thinkingDelta(index: 0, text: "trace"), .thinkingDelta("trace")),
            (.textDelta(index: 0, text: "Hello "), .textDelta("Hello ")),
            (.textDelta(index: 0, text: "world"), .textDelta("world")),
        ]
        do {
            for (delta, expected) in deltas {
                await provider.yield(delta)
                // The broadcast proves the delta was processed; the held-open provider
                // prevents completion from racing the database read.
                let received = await iterator.next()
                #expect(received == expected)
                if let received { events.append(received) }
                let buffered = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
                #expect(buffered.map(\.role) == [.user])
                #expect(buffered.first?.content == "Hi")
            }
        } catch {
            await provider.finish()
            await setup.session.waitUntilFinished()
            throw error
        }

        await provider.yield(.messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 2)))
        await provider.finish()
        while let event = await iterator.next() { events.append(event) }
        await setup.session.waitUntilFinished()

        #expect(events.compactMap { event -> String? in
            if case .textDelta(let text) = event { return text }
            return nil
        } == ["Hello ", "world"])
        let saved = events.compactMap { event -> MessageRecord? in
            if case .assistantMessageSaved(let record) = event { return record }
            return nil
        }
        #expect(saved.count == 1)
        let assistant = try #require(saved.first)
        #expect(events.last == .assistantMessageSaved(assistant))
        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        #expect(stored.map(\.role) == [.user, .assistant])
        #expect(stored.last == assistant)
        #expect(assistant.content == "Hello world")
        #expect(assistant.thinkingContent == "Reasoning trace")
        #expect(assistant.tokenCount == 2)
        #expect(await setup.session.isStreaming == false)
    }

    @Test func providerErrorEventEndsTurnWithErrorAndNoAssistantRow() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .error(.unauthorized),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
        ])
        let stream = await setup.session.send(text: "Hi", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        guard case .error(let llmError) = events.last else {
            Issue.record("expected trailing .error, got \(String(describing: events.last))")
            return
        }
        #expect(llmError == .unauthorized)

        let assistantSavedCount = events.filter {
            if case .assistantMessageSaved = $0 { return true }
            return false
        }.count
        #expect(assistantSavedCount == 0)

        // DB has only the user row.
        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        #expect(stored.map(\.role) == [.user])
    }

    @Test func missingActiveProviderEmitsRequestFailedError() async throws {
        let setup = try await makeSetup(registerProvider: false)
        let stream = await setup.session.send(text: "Hi", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        guard case .error(let llmError) = events.last else {
            Issue.record("expected .error, got \(String(describing: events.last))")
            return
        }
        if case .requestFailed = llmError {
        } else {
            Issue.record("expected .requestFailed, got \(llmError)")
        }
    }

    @Test func priorMessagesArePassedToProviderInChronologicalOrder() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "ok"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 1)),
            ],
        ])
        let now = setup.clock.now()
        try await setup.messageRepo.save(MessageRecord(
            id: "seed-1", conversationId: setup.conversation.id,
            role: .user, content: "previous user", createdAt: now
        ))
        try await setup.messageRepo.save(MessageRecord(
            id: "seed-2", conversationId: setup.conversation.id,
            role: .assistant, content: "previous reply", createdAt: setup.clock.now()
        ))

        let stream = await setup.session.send(text: "third", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let captured = await setup.provider.capturedRequests()
        #expect(captured.count == 1)
        let messages = captured.first?.messages ?? []
        #expect(messages.count == 3)
        #expect(messages[0].role == .user)
        #expect(messages[1].role == .assistant)
        #expect(messages[2].role == .user)

        if case .text(let body) = messages[2].content.first {
            #expect(body == "third")
        } else {
            Issue.record("expected user text content, got \(messages[2].content)")
        }
    }

    @Test func temperatureForwardsToProvider() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
        ])
        let stream = await setup.session.send(text: "Hi", model: setup.model, temperature: 0.42)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let captured = await setup.provider.capturedRequests()
        #expect(captured.first?.temperature == 0.42)
    }

    /// The protocol default drops options unless the provider implements the overload.
    @Test func conversationCacheKeyForwardsToProvider() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
        ])
        let stream = await setup.session.send(text: "Hi", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let captured = await setup.provider.capturedRequests()
        #expect(captured.first?.options.conversationCacheKey == setup.conversation.id)
    }

    @Test func thinkingDeltasSurfaceAsThinkingEvents() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .thinkingDelta(index: 0, text: "reasoning..."),
                .textDelta(index: 1, text: "answer"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 1)),
            ],
        ])
        let stream = await setup.session.send(text: "Hi", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        let thinking = events.compactMap { event -> String? in
            if case .thinkingDelta(let text) = event { return text }
            return nil
        }
        #expect(thinking == ["reasoning..."])
    }

    @Test func thinkingContentPersistsToAssistantRow() async throws {
        // Persist thinking before clearing the streaming tail or the visible trace disappears.
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .thinkingDelta(index: 0, text: "step one. "),
                .thinkingDelta(index: 0, text: "step two."),
                .textDelta(index: 1, text: "the answer"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 1)),
            ],
        ])
        let stream = await setup.session.send(text: "Hi", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        guard case .assistantMessageSaved(let record) = events.last else {
            Issue.record("expected trailing .assistantMessageSaved, got \(String(describing: events.last))")
            return
        }
        let stored = try await setup.messageRepo.fetch(id: record.id)
        #expect(stored?.thinkingContent == "step one. step two.")
        #expect(stored?.content == "the answer")
        // FixedClock does not advance between deltas, so the duration is zero.
        #expect(stored?.thinkingDurationMs == 0)
    }

    @Test func thinkingSignaturePersistsAlongsideTheTrace() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .thinkingDelta(index: 0, text: "reasoning"),
                .thinkingSignature(index: 0, signature: "sig-xyz"),
                .textDelta(index: 1, text: "the answer"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 1)),
            ],
        ])
        let stream = await setup.session.send(text: "Hi", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        guard case .assistantMessageSaved(let record) = events.last else {
            Issue.record("expected trailing .assistantMessageSaved")
            return
        }
        let stored = try await setup.messageRepo.fetch(id: record.id)
        #expect(stored?.thinkingContent == "reasoning")
        #expect(stored?.thinkingSignature == "sig-xyz")
        // Foreign-model signatures are rejected on replay.
        #expect(stored?.thinkingModelId == setup.model.id)
    }

    @Test func thinkingOnlyTurnPersists() async throws {
        // A thinking-only turn is visible output and must survive clearing the streaming tail.
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .thinkingDelta(index: 0, text: "thought, then stopped"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 1)),
            ],
        ])
        let stream = await setup.session.send(text: "Hi", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        guard case .assistantMessageSaved(let record) = events.last else {
            Issue.record("expected trailing .assistantMessageSaved — thinking-only turns must persist")
            return
        }
        let stored = try await setup.messageRepo.fetch(id: record.id)
        #expect(stored?.thinkingContent == "thought, then stopped")
        #expect(stored?.content == "")
    }

    @Test func nonThinkingTurnLeavesThinkingContentNil() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "plain reply"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 1)),
            ],
        ])
        let stream = await setup.session.send(text: "Hi", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        guard case .assistantMessageSaved(let record) = events.last else {
            Issue.record("expected trailing .assistantMessageSaved")
            return
        }
        let stored = try await setup.messageRepo.fetch(id: record.id)
        #expect(stored?.thinkingContent == nil)
        #expect(stored?.thinkingDurationMs == nil)
    }

    @Test func emptyTurnDoesNotPersistAssistantRow() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
        ])
        let stream = await setup.session.send(text: "Hi", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        #expect(stored.map(\.role) == [.user])

        let assistantSaved = events.contains {
            if case .assistantMessageSaved = $0 { return true }
            return false
        }
        #expect(assistantSaved == false)
    }

    @Test func sequentialSendsPersistAllRowsInOrder() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "first reply"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 1)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .textDelta(index: 0, text: "second reply"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 1)),
            ],
        ])
        let stream1 = await setup.session.send(text: "first", model: setup.model)
        _ = await collect(stream1)
        let stream2 = await setup.session.send(text: "second", model: setup.model)
        _ = await collect(stream2)
        await setup.session.waitUntilFinished()

        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        #expect(stored.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(stored.map(\.content) == ["first", "first reply", "second", "second reply"])
    }

    @Test func backToBackSendsSerializeViaPriorTaskFence() async throws {
        // A new send must drain cancellation of the prior task even if its stream is unconsumed.
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "first reply"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 1)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .textDelta(index: 0, text: "second reply"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 1)),
            ],
        ])
        _ = await setup.session.send(text: "first", model: setup.model)
        let stream2 = await setup.session.send(text: "second", model: setup.model)
        let events2 = await collect(stream2)
        await setup.session.waitUntilFinished()

        let active = await setup.session.isStreaming
        #expect(active == false)

        guard case .assistantMessageSaved(let saved) = events2.last else {
            Issue.record("expected stream2 to end with .assistantMessageSaved, got \(String(describing: events2.last))")
            return
        }
        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        #expect(stored.contains { $0.role == .user && $0.content == "second" })
        #expect(stored.contains { $0.id == saved.id })
    }

    @Test func setUserPersonalizationPropagatesToNextProviderRequest() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "first"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 1)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .textDelta(index: 0, text: "second"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 1)),
            ],
        ])

        let stream1 = await setup.session.send(text: "hi", model: setup.model)
        _ = await collect(stream1)
        await setup.session.waitUntilFinished()

        let firstRequest = await setup.provider.capturedRequests().first
        #expect(firstRequest?.messages.contains(where: { $0.role == .system }) == false)

        await setup.session.setUserPersonalization("Always answer in haiku.")
        let stream2 = await setup.session.send(text: "again", model: setup.model)
        _ = await collect(stream2)
        await setup.session.waitUntilFinished()

        let secondRequest = await setup.provider.capturedRequests().last
        #expect(secondRequest?.messages.first?.role == .system)
        if case .text(let body) = secondRequest?.messages.first?.content.first {
            #expect(body.contains("## User personalization"))
            #expect(body.contains("Always answer in haiku."))
        } else {
            Issue.record("expected leading .system text, got \(String(describing: secondRequest?.messages.first?.content))")
        }
    }

    @Test func subscribeOnQuiescentSessionReturnsNilSnapshotAndFinishedStream() async throws {
        let setup = try await makeSetup()

        let (snapshot, stream) = await setup.session.subscribe()
        #expect(snapshot == nil)

        var events: [ChatEvent] = []
        for await event in stream { events.append(event) }
        #expect(events.isEmpty)
    }

    @Test func subscribeDuringToolPauseDeliversRemainingEventsToLateSubscriber() async throws {
        let toolID = "test.resumable"
        let toolDef = LLMTool(
            id: toolID,
            name: "resumable",
            description: "Test tool that waits for an external resume signal.",
            category: .query,
            parameters: [],
            appletId: "test"
        )
        let resumableExecutor = ResumableToolExecutor(toolID: toolID)

        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "thinking"),
                .toolUse(index: 1, id: "tc-1", name: toolID, input: .object([:]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .textDelta(index: 0, text: " done"),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
        ])
        await setup.toolRegistry.register(ToolRegistration(tool: toolDef, execution: .local(resumableExecutor)))

        let firstStream = await setup.session.send(text: "kick", model: setup.model)
        async let firstEvents: [ChatEvent] = self.collect(firstStream)

        // Pause after the first assistant save and before the second round, so a
        // late subscriber must receive the remaining tool and text events.
        await resumableExecutor.awaitFirstCall()

        let (snapshot, lateStream) = await setup.session.subscribe()
        #expect(snapshot != nil)
        async let lateEvents: [ChatEvent] = self.collect(lateStream)

        await resumableExecutor.resume(with: ToolResult(toolID: toolID, content: "{}", isError: false))

        let (early, late) = await (firstEvents, lateEvents)
        await setup.session.waitUntilFinished()

        #expect(early.contains { if case .assistantMessageSaved = $0 { return true }; return false })

        let lateAssistantSaved = late.filter {
            if case .assistantMessageSaved = $0 { return true }
            return false
        }
        #expect(lateAssistantSaved.count >= 1, "late subscriber must see at least one .assistantMessageSaved")

        let lateToolCompleted = late.contains {
            if case .toolCallCompleted = $0 { return true }
            return false
        }
        #expect(lateToolCompleted)
    }

    @Test func subscribeMidThinkingReturnsSnapshotWithStartedAt() async throws {
        // Late subscribers need the original thinking start time or navigation resets the counter.
        let database = try ChatDatabase.makeInMemory()
        let messageRepo = GRDBMessageRepository(database: database)
        let toolCallRepo = GRDBToolCallRepository(database: database)
        let checkpointRepo = GRDBCompactionCheckpointRepository(database: database)
        let clock = OrchestrationFixtures.defaultClock()
        let idGen = DeterministicIDGenerator(prefix: "id-", start: 0)
        let conversation = try await OrchestrationFixtures.seedConversation(in: database, clock: clock)
        let model = OrchestrationFixtures.defaultModel()
        let provider = PausableLLMProvider(model: model)
        let llmRegistry = LLMProviderRegistry()
        await llmRegistry.register(provider)
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
            toolRegistry: ToolRegistry(),
            compactor: compactor,
            clock: clock,
            idGenerator: idGen,
            autoCompactEnabled: false
        )

        // Receiving the broadcast proves the actor stored thinkingStartedAt before subscribe().
        let firstStream = await session.send(text: "Hi", model: model)
        var firstIter = firstStream.makeAsyncIterator()

        _ = await firstIter.next()

        await provider.yield(.thinkingDelta(index: 0, text: "reasoning..."))
        let broadcast = await firstIter.next()
        guard case .thinkingDelta = broadcast else {
            Issue.record("expected broadcast of .thinkingDelta, got \(String(describing: broadcast))")
            await provider.finish()
            await session.waitUntilFinished()
            return
        }

        let (snapshot, _) = await session.subscribe()
        #expect(snapshot != nil)
        #expect(snapshot?.accumulatedThinking == "reasoning...")
        #expect(snapshot?.thinkingStartedAt == clock.now())

        await provider.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
        await provider.finish()
        await session.waitUntilFinished()
    }

    @Test func turnSurvivesWhenConsumerDropsTheStream() async throws {
        // ChatSession owns turn lifetime independently of UI subscriptions. Dropping
        // the returned stream must still let the assistant row reach GRDB.
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "complete"),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
        ])

        _ = await setup.session.send(text: "Hello", model: setup.model)

        await setup.session.waitUntilFinished()

        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        let assistant = stored.first(where: { $0.role == .assistant })
        #expect(assistant != nil, "assistant turn must persist even when no consumer is listening")
        #expect(assistant?.content == "complete")
    }

    @Test func retryRunsLLMLoopWithoutWritingANewUserMessage() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "retry ok"),
                .messageComplete(usage: TokenUsage(inputTokens: 5, outputTokens: 2)),
            ],
        ])
        try await setup.messageRepo.save(MessageRecord(
            id: "u-seed",
            conversationId: setup.conversation.id,
            role: .user,
            content: "test",
            createdAt: setup.clock.now()
        ))

        let stream = await setup.session.retry(model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        let userRows = stored.filter { $0.role == .user }
        #expect(userRows.count == 1)
        #expect(userRows.first?.id == "u-seed")
        let userSavedCount = events.filter {
            if case .userMessageSaved = $0 { return true }
            return false
        }.count
        #expect(userSavedCount == 0)
        let captured = await setup.provider.capturedRequests()
        #expect(captured.count == 1)
        let messages = captured.first?.messages ?? []
        let userTexts = messages.filter { $0.role == .user }.compactMap { msg -> String? in
            if case .text(let body) = msg.content.first { return body }
            return nil
        }
        #expect(userTexts == ["test"])
        let assistantSavedCount = events.filter {
            if case .assistantMessageSaved = $0 { return true }
            return false
        }.count
        #expect(assistantSavedCount == 1)
        #expect(stored.contains(where: { $0.role == .assistant && $0.content == "retry ok" }))
    }

    @Test func retryWithNoPriorUserMessageIsASilentNoOp() async throws {
        let setup = try await makeSetup(scripts: [])

        let stream = await setup.session.retry(model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        #expect(events.isEmpty)
        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        #expect(stored.isEmpty)
        let captured = await setup.provider.capturedRequests()
        #expect(captured.isEmpty)
    }
}

