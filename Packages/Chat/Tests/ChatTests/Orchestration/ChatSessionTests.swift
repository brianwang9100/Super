import Core
import Foundation
import Testing

@testable import Chat

/// Tests for `ChatSession`'s single-turn behavior: persistence ordering,
/// streaming-text accumulation per ADR-BB-003 (write only on
/// `.messageComplete`), event sequence, and provider failure surfaces.
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
        // A verse pill carried on `send(references:)` must be encoded onto
        // the persisted user `MessageRecord` so the sent bubble re-renders
        // the pill and `ContextAssembler` can expand it for the LLM.
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
        // `encode` returns nil for an empty reference set, so a plain
        // message must leave `attachmentsJSON` NULL — not an empty JSON blob.
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

    @Test func textDeltasAccumulateAndAssistantSavesOnceOnMessageComplete() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "Hello "),
                .textDelta(index: 0, text: "world"),
                .messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 2)),
            ],
        ])
        let stream = await setup.session.send(text: "Hi", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        // Two textDelta events surface to the view.
        let textDeltas = events.compactMap { event -> String? in
            if case .textDelta(let text) = event { return text }
            return nil
        }
        #expect(textDeltas == ["Hello ", "world"])

        // Exactly one assistant message lands in the database, with
        // the accumulated text and the usage's output token count.
        let assistantSavedCount = events.filter {
            if case .assistantMessageSaved = $0 { return true }
            return false
        }.count
        #expect(assistantSavedCount == 1)

        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        #expect(stored.map(\.role) == [.user, .assistant])
        #expect(stored.last?.content == "Hello world")
        #expect(stored.last?.tokenCount == 2)
    }

    @Test func intermediateTextDeltasNeverWriteToDatabase() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "a"),
                .textDelta(index: 0, text: "b"),
                .textDelta(index: 0, text: "c"),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
        ])
        let stream = await setup.session.send(text: "ping", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        // 1 user + 1 assistant only — no per-delta intermediate rows.
        #expect(stored.count == 2)
        #expect(stored.last?.content == "abc")
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

        // Last event is the terminal .error.
        guard case .error(let llmError) = events.last else {
            Issue.record("expected trailing .error, got \(String(describing: events.last))")
            return
        }
        #expect(llmError == .unauthorized)

        // No .assistantMessageSaved fired.
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
            // expected
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
        // Pre-seed two prior messages.
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

        // The new user turn carries the submitted text.
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
        // Two thinking deltas + a text delta should be stitched into a
        // single `thinkingContent` value on the saved row so the UI can
        // re-render the trace after the streaming tail clears. Without
        // this we'd lose the trace the moment `.assistantMessageSaved`
        // fires — see the bug discussion in `MessageList.swift`.
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
        // Duration is non-nil whenever thinking happened. The fixed-clock
        // FakeLLMProvider yields every event at the same instant so the
        // measured value is 0 ms, which is the correct lower bound.
        #expect(stored?.thinkingDurationMs == 0)
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

    @Test func assistantMessageSavedEventCarriesPersistedRow() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "done"),
                .messageComplete(usage: TokenUsage(inputTokens: 3, outputTokens: 4)),
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
        #expect(stored?.id == record.id)
        #expect(stored?.role == record.role)
        #expect(stored?.content == record.content)
        #expect(stored?.tokenCount == 4)
    }

    @Test func isStreamingFlipsBackToFalseAfterTurnCompletes() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "ok"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 1)),
            ],
        ])
        let stream = await setup.session.send(text: "Hi", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()
        let active = await setup.session.isStreaming
        #expect(active == false)
    }

    @Test func emptyTurnDoesNotPersistAssistantRow() async throws {
        // Provider terminates the turn without text or tool calls.
        // Per ADR-BB-003 and the empty-turn rule, no assistant row is
        // written and `assembleHistory` stays consistent with the DB.
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
        ])
        let stream = await setup.session.send(text: "Hi", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        // Only the user row is persisted.
        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        #expect(stored.map(\.role) == [.user])

        // No `.assistantMessageSaved` event surfaces.
        let assistantSaved = events.contains {
            if case .assistantMessageSaved = $0 { return true }
            return false
        }
        #expect(assistantSaved == false)
    }

    @Test func sequentialSendsPersistAllRowsInOrder() async throws {
        // The natural sequential flow: caller awaits the first stream's
        // events fully, then sends again. Both turns should land in the
        // database in strict order with the rowid tiebreaker resolving
        // any timestamp ties.
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
        // The fix for the send-race makes `send(...)` cancel the prior
        // task and then await its wind-down before the new turn starts.
        // Even when a caller fires two sends without consuming the first
        // stream, the second stream completes cleanly with its own script
        // and the session ends in a quiescent state — no zombie task,
        // no hang.
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
        // The second send's user row is unambiguously persisted.
        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        #expect(stored.contains { $0.role == .user && $0.content == "second" })
        #expect(stored.contains { $0.id == saved.id })
    }

    @Test func setUserPersonalizationPropagatesToNextProviderRequest() async throws {
        // Two scripted turns so we can verify the value change is picked
        // up *between* turns — the first turn carries no personalization
        // (no `.system` row), the second carries the value pushed via
        // `setUserPersonalization(...)` under the
        // `## User personalization` section header.
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

        // Turn 1: no personalization configured, no .system row in request.
        let stream1 = await setup.session.send(text: "hi", model: setup.model)
        _ = await collect(stream1)
        await setup.session.waitUntilFinished()

        // Assert *no* `.system` row anywhere in the first request — not just
        // at index 0. Seeding-fixture changes that ever introduce a leading
        // `.system` row should fail this test loudly rather than silently
        // pass through an index-0 check.
        let firstRequest = await setup.provider.capturedRequests().first
        #expect(firstRequest?.messages.contains(where: { $0.role == .system }) == false)

        // Turn 2: push personalization, send another message, observe it
        // injected as the leading .system row's personalization section.
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
        // No turn in flight: `subscribe()` is the documented hook for a
        // newly-mounted view model to ask "anything streaming for this
        // conversation?". It must answer cleanly without spinning up any
        // work — `snapshot == nil` and the stream finishes immediately
        // so the caller's `for await` loop exits without hanging.
        let setup = try await makeSetup()

        let (snapshot, stream) = await setup.session.subscribe()
        #expect(snapshot == nil)

        var events: [ChatEvent] = []
        for await event in stream { events.append(event) }
        #expect(events.isEmpty)
    }

    @Test func subscribeDuringToolPauseDeliversRemainingEventsToLateSubscriber() async throws {
        // The plan's central contract: a view model that mounts mid-turn
        // can re-attach via `subscribe()` and receive every subsequent
        // `ChatEvent` from the in-flight turn — including the terminal
        // `.assistantMessageSaved` once the tool resumes. We pause the
        // turn inside the tool loop (a deterministic synchronization
        // point exposed via `awaitFirstCall()`), attach a second
        // subscriber, then resume the tool and assert that the late
        // subscriber's stream carries the rest of the turn through to
        // completion.
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
                .toolUse(index: 1, id: "tc-1", name: toolID, input: .object([:])),
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

        // Sync on the tool actually starting — the turn is now paused
        // mid-loop, after the first round's `.assistantMessageSaved`
        // (which resets the accumulators on the actor) and before the
        // second round begins. Subscribing here proves the late
        // subscriber sees `.toolCallCompleted`, the second round's
        // `.textDelta`, and the final `.assistantMessageSaved`.
        await resumableExecutor.awaitFirstCall()

        let (snapshot, lateStream) = await setup.session.subscribe()
        #expect(snapshot != nil)
        async let lateEvents: [ChatEvent] = self.collect(lateStream)

        // Resume the tool: the turn finishes its second round-trip and
        // emits `.assistantMessageSaved`. Both subscribers' streams
        // close after `finishLiveTurn()`.
        await resumableExecutor.resume(with: ToolResult(toolID: toolID, content: "{}", isError: false))

        let (early, late) = await (firstEvents, lateEvents)
        await setup.session.waitUntilFinished()

        // The early subscriber saw the full turn including the first
        // round's `.assistantMessageSaved`.
        #expect(early.contains { if case .assistantMessageSaved = $0 { return true }; return false })

        // The late subscriber saw `.toolCallCompleted` and the second
        // round's `.assistantMessageSaved` — proving the fan-out kept
        // delivering events to it through the rest of the turn.
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
        // Regression: when the user navigated away from a still-thinking
        // chat and back, the "Thought for Xs" counter reset to 0. Cause:
        // `thinkingStartedAt` lived as a local in `streamOneTurn`, so a
        // late-attaching subscriber's `LiveTurnSnapshot` couldn't carry
        // it and the view model fell back to `Date()` (now). This test
        // pins the contract that the actor holds the start time and
        // exposes it through the snapshot. Without the fix, the
        // `snapshot.thinkingStartedAt` assertion below trips on `nil`.
        let database = try ChatDatabase.makeInMemory()
        let conversationRepo = GRDBConversationRepository(database: database)
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

        // Start the turn. `send(...)` returns a stream we iterate to
        // observe broadcasts; reading the first `.thinkingDelta` off it
        // is the deterministic sync point that proves the actor has
        // already executed the `case .thinkingDelta` block (which sets
        // `liveTurn?.thinkingStartedAt`) before we call `subscribe()`.
        let firstStream = await session.send(text: "Hi", model: model)
        var firstIter = firstStream.makeAsyncIterator()

        // Skip the leading `.userMessageSaved` so the next event we read
        // is the broadcast for our thinking delta.
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

        // Wind the turn down so the test fixture cleans up.
        await provider.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
        await provider.finish()
        await session.waitUntilFinished()
    }

    @Test func turnSurvivesWhenConsumerDropsTheStream() async throws {
        // The architecture contract (ChatSession docstring lines 8-12, mirrored
        // in ChatSessionStore lines 7-10) is: switching away from a streaming
        // chat in the UI must not cancel the underlying turn. The session's
        // task is supposed to live independent of the returned AsyncStream's
        // iteration, so the final `MessageRecord` always lands in GRDB.
        //
        // This test drops the stream without ever iterating it — modeling the
        // host `rebuildChatViewModel` swap where the old view model (and the
        // AsyncStream it was iterating) is released mid-turn. The turn must
        // still complete and persist the assistant row.
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "complete"),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
        ])

        // Discard the returned stream immediately. AsyncStream fires its
        // `onTermination` handler when the stream is released without an
        // active iterator — on `main` this cancels `currentTask` and aborts
        // the turn before `.messageComplete` is processed.
        _ = await setup.session.send(text: "Hello", model: setup.model)

        await setup.session.waitUntilFinished()

        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        let assistant = stored.first(where: { $0.role == .assistant })
        #expect(assistant != nil, "assistant turn must persist even when no consumer is listening")
        #expect(assistant?.content == "complete")
    }
}

