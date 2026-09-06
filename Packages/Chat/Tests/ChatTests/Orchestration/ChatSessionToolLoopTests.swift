import Core
import Foundation
import Testing

@testable import Chat

/// Tests for `ChatSession`'s tool loop: pending → executing → success
/// transitions, tool result `MessageRecord` round-trip, multi-turn history
/// assembly, and enabled-tool filtering before the LLM (Large Language
/// Model) sees the catalog.
@Suite("ChatSession tool loop")
struct ChatSessionToolLoopTests {

    private struct Setup {
        let database: ChatDatabase
        let messageRepo: GRDBMessageRepository
        let toolCallRepo: GRDBToolCallRepository
        let conversationRepo: GRDBConversationRepository
        let llmRegistry: LLMProviderRegistry
        let toolRegistry: ToolRegistry
        let clock: FixedClock
        let provider: FakeLLMProvider
        let conversation: ConversationRecord
        let model: LLMModel
        let session: ChatSession
    }

    private func makeSetup(scripts: [[LLMStreamEvent]] = []) async throws -> Setup {
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
        await llmRegistry.register(provider)
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
            database: database, messageRepo: messageRepo, toolCallRepo: toolCallRepo,
            conversationRepo: conversationRepo, llmRegistry: llmRegistry,
            toolRegistry: toolRegistry, clock: clock, provider: provider,
            conversation: conversation, model: model, session: session
        )
    }

    private func collect(_ stream: AsyncStream<ChatEvent>) async -> [ChatEvent] {
        var events: [ChatEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func makeTool(id: String) -> LLMTool {
        LLMTool(
            id: id, name: id, description: "test tool",
            category: .query, parameters: [], appletId: "test"
        )
    }

    @Test func loopExecutesToolThenContinuesUntilLLMFinishesWithoutToolCalls() async throws {
        let toolID = "test.echo"
        let setup = try await makeSetup(scripts: [
            // Turn 1: assistant emits some text + a tool call.
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "checking..."),
                .toolUse(index: 0, id: "tc-1", name: toolID, input: .object(["q": .string("ping")]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
            // Turn 2: after the tool returns, the assistant finishes plainly.
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .textDelta(index: 0, text: "result was 'pong'"),
                .messageComplete(usage: TokenUsage(inputTokens: 5, outputTokens: 4)),
            ],
        ])
        let executor = FakeToolExecutor(toolID: toolID)
        await executor.setResult(ToolResult(toolID: toolID, content: "pong", isError: false))
        await setup.toolRegistry.register(ToolRegistration(tool: makeTool(id: toolID), execution: .local(executor)))

        let stream = await setup.session.send(text: "ping the tool", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        // The tool was invoked once.
        let count = await executor.executionCount()
        #expect(count == 1)
        // ...with the parameters the LLM emitted.
        let inputs = await executor.capturedInputs()
        #expect(inputs.first?["q"] == .string("ping"))

        // Persisted ToolCallRecord landed at status .success with the
        // result body JSON-encoded.
        let storedCall = try await setup.toolCallRepo.fetch(id: "tc-1")
        #expect(storedCall?.status == .success)
        #expect(storedCall?.toolName == toolID)
        #expect(storedCall?.completedAt != nil)

        // Conversation now has user + assistant1 + tool result + assistant2.
        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        #expect(stored.map(\.role) == [.user, .assistant, .tool, .assistant])
        // The .tool row is linked back to the call.
        let toolRow = stored[2]
        #expect(toolRow.toolCallId == "tc-1")
        #expect(toolRow.content == "pong")
        // The final assistant carries the second-turn text.
        #expect(stored.last?.content == "result was 'pong'")

        // Event sequence carried both lifecycle markers for the tool call.
        let kinds = events.map { event -> String in
            switch event {
            case .modelResolved: return "modelResolved"
            case .userMessageSaved: return "user"
            case .textDelta: return "text"
            case .thinkingDelta: return "thinking"
            case .toolCallStarted: return "toolStarted"
            case .toolCallAwaitingConfirmation: return "toolAwaitingConfirmation"
            case .toolCallCompleted: return "toolCompleted"
            case .toolCallFailed: return "toolFailed"
            case .assistantMessageSaved: return "assistantSaved"
            case .compactionStarted: return "compactionStarted"
            case .compactionCompleted: return "compactionCompleted"
            case .error: return "error"
            }
        }
        // Order around the tool: assistant text, assistant saved, tool
        // started, tool completed, second-turn text, final assistant saved.
        #expect(kinds.contains("toolStarted"))
        #expect(kinds.contains("toolCompleted"))
        #expect(!kinds.contains("toolFailed"))
        #expect(!kinds.contains("error"))
    }

    @Test func secondTurnHistoryIncludesToolUseAndToolResultBlocks() async throws {
        let toolID = "test.lookup"
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .toolUse(index: 0, id: "tc-x", name: toolID, input: .object([:]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .textDelta(index: 0, text: "ok"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
        ])
        let executor = FakeToolExecutor(toolID: toolID)
        await executor.setResult(ToolResult(toolID: toolID, content: "{\"data\":42}", isError: false))
        await setup.toolRegistry.register(ToolRegistration(tool: makeTool(id: toolID), execution: .local(executor)))

        let stream = await setup.session.send(text: "look it up", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let captured = await setup.provider.capturedRequests()
        #expect(captured.count == 2)

        let secondTurnMessages = captured[1].messages
        // user, assistant(toolUse only — empty text), tool(result)
        #expect(secondTurnMessages.count == 3)
        #expect(secondTurnMessages[1].role == .assistant)
        if case .toolUse(let id, let name, _, _) = secondTurnMessages[1].content.first {
            #expect(id == "tc-x")
            #expect(name == toolID)
        } else {
            Issue.record("expected first assistant block to be .toolUse, got \(secondTurnMessages[1].content)")
        }
        #expect(secondTurnMessages[2].role == .tool)
        if case .toolResult(let toolUseID, let content, let isError) = secondTurnMessages[2].content.first {
            #expect(toolUseID == "tc-x")
            #expect(content == "{\"data\":42}")
            #expect(isError == false)
        } else {
            Issue.record("expected tool message to carry .toolResult, got \(secondTurnMessages[2].content)")
        }
    }

    @Test func toolExecutionFailureMarksRecordFailedAndFeedsErrorBackToLLM() async throws {
        let toolID = "test.broken"
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .toolUse(index: 0, id: "tc-bad", name: toolID, input: .object([:]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .textDelta(index: 0, text: "sorry, that failed"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
        ])
        let executor = FakeToolExecutor(toolID: toolID)
        await executor.setError(.scripted("DB locked"))
        await setup.toolRegistry.register(ToolRegistration(tool: makeTool(id: toolID), execution: .local(executor)))

        let stream = await setup.session.send(text: "do it", model: setup.model)
        let events = await collect(stream)
        await setup.session.waitUntilFinished()

        // ToolCallRecord ended at .failed with an error result body.
        let storedCall = try await setup.toolCallRepo.fetch(id: "tc-bad")
        #expect(storedCall?.status == .failed)
        #expect(storedCall?.completedAt != nil)

        // A .toolCallFailed event surfaced.
        let failed = events.contains { event in
            if case .toolCallFailed = event { return true }
            return false
        }
        #expect(failed)

        // The second turn's history carries the failure as an isError tool
        // result — that is how the LLM learns to apologize.
        let captured = await setup.provider.capturedRequests()
        #expect(captured.count == 2)
        let toolRow = captured[1].messages.last
        #expect(toolRow?.role == .tool)
        if case .toolResult(_, _, let isError) = toolRow?.content.first {
            #expect(isError == true)
        } else {
            Issue.record("expected isError tool result, got \(String(describing: toolRow?.content))")
        }
    }

    @Test func disabledToolsAreFilteredBeforeReachingTheProvider() async throws {
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
        ])
        let enabledExecutor = FakeToolExecutor(toolID: "test.on")
        let disabledExecutor = FakeToolExecutor(toolID: "test.off")
        await setup.toolRegistry.register(ToolRegistration(
            tool: makeTool(id: "test.on"), execution: .local(enabledExecutor), isEnabled: true
        ))
        await setup.toolRegistry.register(ToolRegistration(
            tool: makeTool(id: "test.off"), execution: .local(disabledExecutor), isEnabled: false
        ))

        let stream = await setup.session.send(text: "hi", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let captured = await setup.provider.capturedRequests()
        let toolIDs = captured.first?.tools.map(\.id).sorted() ?? []
        #expect(toolIDs == ["test.on"])
    }

    @Test func failedToolCallResultColumnDecodesAsToolResult() async throws {
        // The result column should always hold a JSON-encoded `ToolResult`
        // — both on success and failure — so admin tools and analytics
        // can `decodedResult()` without distinguishing the two paths.
        let toolID = "test.broken.parse"
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .toolUse(index: 0, id: "tc-parse", name: toolID, input: .object([:]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
        ])
        let executor = FakeToolExecutor(toolID: toolID)
        await executor.setError(.scripted("kaboom"))
        await setup.toolRegistry.register(ToolRegistration(tool: makeTool(id: toolID), execution: .local(executor)))

        let stream = await setup.session.send(text: "do it", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let storedCall = try await setup.toolCallRepo.fetch(id: "tc-parse")
        guard let resultJSON = storedCall?.result else {
            Issue.record("expected stored result")
            return
        }
        let data = Data(resultJSON.utf8)
        let decoded = try JSONDecoder().decode(ToolResult.self, from: data)
        #expect(decoded.isError == true)
        #expect(decoded.content.contains("kaboom"))
    }

    @Test func toolFailurePersistsTheToolResultMessageRow() async throws {
        // Regression test for the prior `try?`-swallowed DB writes in the
        // failure branch. The error-content `MessageRecord` (role .tool)
        // must actually land so the next turn's history carries it.
        let toolID = "test.broken.row"
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .toolUse(index: 0, id: "tc-row", name: toolID, input: .object([:]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
        ])
        let executor = FakeToolExecutor(toolID: toolID)
        await executor.setError(.scripted("nope"))
        await setup.toolRegistry.register(ToolRegistration(tool: makeTool(id: toolID), execution: .local(executor)))

        let stream = await setup.session.send(text: "do it", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        let toolRow = stored.first(where: { $0.role == .tool })
        #expect(toolRow != nil)
        #expect(toolRow?.toolCallId == "tc-row")
        #expect(toolRow?.content.contains("nope") == true)
    }

    @Test func multipleToolCallsInOneTurnAreAllExecutedSequentially() async throws {
        // The provider can emit several `.toolUse` events in one turn
        // (parallel function calling). The orchestrator runs them one at
        // a time in emission order; each should be persisted, executed,
        // and yield its own ChatEvent triplet.
        let toolA = "test.a"
        let toolB = "test.b"
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .toolUse(index: 0, id: "tc-a", name: toolA, input: .object([:]), signature: nil),
                .toolUse(index: 1, id: "tc-b", name: toolB, input: .object([:]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .textDelta(index: 0, text: "all done"),
                .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 1)),
            ],
        ])
        let executorA = FakeToolExecutor(toolID: toolA)
        let executorB = FakeToolExecutor(toolID: toolB)
        await executorA.setResult(ToolResult(toolID: toolA, content: "A"))
        await executorB.setResult(ToolResult(toolID: toolB, content: "B"))
        await setup.toolRegistry.register(ToolRegistration(tool: makeTool(id: toolA), execution: .local(executorA)))
        await setup.toolRegistry.register(ToolRegistration(tool: makeTool(id: toolB), execution: .local(executorB)))

        let stream = await setup.session.send(text: "go", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let countA = await executorA.executionCount()
        let countB = await executorB.executionCount()
        #expect(countA == 1)
        #expect(countB == 1)

        let storedCalls = try await setup.toolCallRepo.fetchByConversation(setup.conversation.id)
        #expect(storedCalls.map(\.id) == ["tc-a", "tc-b"])
        #expect(storedCalls.allSatisfy { $0.status == .success })

        // Second turn's history carries both tool results, in order.
        let captured = await setup.provider.capturedRequests()
        #expect(captured.count == 2)
        let toolRows = captured[1].messages.filter { $0.role == .tool }
        #expect(toolRows.count == 2)
    }

    @Test func citationsArePersistedOntoAssistantMessageDedupedByURL() async throws {
        let dupeURL = URL(string: "https://example.com/a")!
        let otherURL = URL(string: "https://example.com/b")!
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .searchStarted(query: "history of westphalia"),
                .textDelta(index: 0, text: "The treaty was signed in 1648."),
                // Two citation events; the second repeats `dupeURL`, which must
                // collapse to a single stored source (first-seen wins).
                .citations([
                    SourceCitation(id: "s1", title: "A", url: dupeURL),
                    SourceCitation(id: "s2", title: "B", url: otherURL),
                ]),
                .citations([
                    SourceCitation(id: "s3", title: "A (dupe)", url: dupeURL),
                ]),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
        ])

        let stream = await setup.session.send(text: "tell me about the treaty", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        let assistant = try #require(stored.last)
        #expect(assistant.role == .assistant)
        let sources = assistant.attachments?.sources ?? []
        #expect(sources.count == 2)
        #expect(sources.map(\.url) == [dupeURL, otherURL])
        // First-seen wins on dedupe: the later "A (dupe)" title is discarded.
        #expect(sources.first?.title == "A")
    }

    @Test func citationsOnlyTurnWithoutTextStillPersistsAssistantMessageWithSources() async throws {
        // A native provider may emit citations + .messageComplete with no text
        // and no tool calls. The empty-turn guard must NOT discard this turn,
        // or the sources are lost for good (they persist only on this path).
        let url = URL(string: "https://example.com/grounded")!
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .searchStarted(query: "q"),
                .citations([SourceCitation(id: "s1", title: "Grounded", url: url)]),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 0)),
            ],
        ])

        let stream = await setup.session.send(text: "ground this", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        // user + assistant(citations-only); the assistant row must exist.
        #expect(stored.map(\.role) == [.user, .assistant])
        let assistant = try #require(stored.last)
        #expect(assistant.content.isEmpty)
        #expect(assistant.attachments?.sources.map(\.url) == [url])
    }

    @Test func citationDedupeIsCaseInsensitiveOnSchemeAndHost() async throws {
        // RFC 3986: scheme + host are case-insensitive, path is not. The two
        // URLs below differ only in host/scheme casing → one stored source.
        let first = URL(string: "https://Example.com/Article")!
        let dupe = URL(string: "HTTPS://example.com/Article")!
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "grounded"),
                .citations([
                    SourceCitation(id: "s1", title: "First", url: first),
                    SourceCitation(id: "s2", title: "Dupe (case)", url: dupe),
                ]),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
        ])

        let stream = await setup.session.send(text: "q", model: setup.model)
        _ = await collect(stream)
        await setup.session.waitUntilFinished()

        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        let sources = try #require(stored.last?.attachments?.sources)
        #expect(sources.count == 1)
        #expect(sources.first?.title == "First")
    }

    /// Cancelling a turn while a tool executes must not orphan the persisted
    /// `tool_use` rows: the in-flight call *and* every not-yet-run call in
    /// the same batch get a cancelled status, a `completedAt`, and a
    /// role-`.tool` result row — so the next turn's history is provider-valid.
    /// Regression for audit P0-2 (cancel mid-tool permanently wedged the
    /// conversation with recurring provider 400s).
    @Test func cancelDuringToolExecutionWritesCancelledResultsForWholeBatch() async throws {
        let slowToolID = "test.slow"
        let fastToolID = "test.fast"
        let slowExecutor = ResumableToolExecutor(toolID: slowToolID)
        let fastExecutor = FakeToolExecutor(toolID: fastToolID)
        await fastExecutor.setResult(ToolResult(toolID: fastToolID, content: "never runs", isError: false))

        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .textDelta(index: 0, text: "running tools"),
                .toolUse(index: 0, id: "tc-slow", name: slowToolID, input: .object([:]), signature: nil),
                .toolUse(index: 1, id: "tc-fast", name: fastToolID, input: .object([:]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
        ])
        await setup.toolRegistry.register(
            ToolRegistration(tool: makeTool(id: slowToolID), execution: .local(slowExecutor))
        )
        await setup.toolRegistry.register(
            ToolRegistration(tool: makeTool(id: fastToolID), execution: .local(fastExecutor))
        )

        let stream = await setup.session.send(text: "run both", model: setup.model)
        async let events: [ChatEvent] = self.collect(stream)

        // Deterministic pause: the slow tool has started, so the session is
        // suspended inside `executeToolCalls` with both `tool_use` rows
        // already persisted and neither result written.
        await slowExecutor.awaitFirstCall()
        await setup.session.cancel()
        // Unblock the executor — `ResumableToolExecutor.awaitResume()` is not
        // cancellation-aware (it models a tool that returns normally after
        // the turn was cancelled; the result must be discarded).
        await slowExecutor.resume(with: ToolResult(toolID: slowToolID, content: "late", isError: false))
        _ = await events
        await setup.session.waitUntilFinished()

        // Both calls resolved to .cancelled with a completion timestamp.
        let slowCall = try #require(await setup.toolCallRepo.fetch(id: "tc-slow"))
        let fastCall = try #require(await setup.toolCallRepo.fetch(id: "tc-fast"))
        #expect(slowCall.status == .cancelled)
        #expect(fastCall.status == .cancelled)
        #expect(slowCall.completedAt != nil)
        #expect(fastCall.completedAt != nil)

        // Both have persisted role-.tool result rows linked back to the call.
        let stored = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        let toolRows = stored.filter { $0.role == .tool }
        #expect(toolRows.map(\.toolCallId).sorted { ($0 ?? "") < ($1 ?? "") } == ["tc-fast", "tc-slow"])

        // The fast tool never actually executed.
        let fastCount = await fastExecutor.executionCount()
        #expect(fastCount == 0)

        // And the next turn ships a pair-complete history to the provider.
        await setup.provider.enqueue([
            .messageStart(id: "m2", model: "fake-model-1"),
            .textDelta(index: 0, text: "fresh turn"),
            .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
        ])
        let secondStream = await setup.session.send(text: "continue", model: setup.model)
        _ = await collect(secondStream)
        await setup.session.waitUntilFinished()

        let requests = await setup.provider.capturedRequests()
        let lastRequest = try #require(requests.last)
        var toolUseIDs: [String] = []
        var toolResultIDs: [String] = []
        for message in lastRequest.messages {
            for block in message.content {
                if case .toolUse(let id, _, _, _) = block { toolUseIDs.append(id) }
                if case .toolResult(let id, _, _) = block { toolResultIDs.append(id) }
            }
        }
        #expect(toolUseIDs.sorted() == ["tc-fast", "tc-slow"])
        #expect(toolResultIDs.sorted() == ["tc-fast", "tc-slow"])
    }

    /// Auto-compaction fires at the top of *every* tool-loop iteration —
    /// including the follow-up right after tool results persist. When the
    /// cut would split the just-executed 4-call batch, the backward snap
    /// keeps the whole round-trip verbatim: the follow-up request must
    /// carry the assistant's four `toolUse` blocks with all four real
    /// results (no synthesized "interrupted" text) plus the fresh
    /// checkpoint summary, and the checkpoint must land on a clean
    /// turn boundary.
    @Test func midLoopAutoCompactionKeepsFollowUpPairComplete() async throws {
        let toolID = "test.batch"
        let database = try ChatDatabase.makeInMemory()
        let messageRepo = GRDBMessageRepository(database: database)
        let toolCallRepo = GRDBToolCallRepository(database: database)
        let checkpointRepo = GRDBCompactionCheckpointRepository(database: database)
        let clock = OrchestrationFixtures.defaultClock()
        let idGen = DeterministicIDGenerator(prefix: "id-", start: 0)
        let conversation = try await OrchestrationFixtures.seedConversation(in: database, clock: clock)

        // Full-tier window so `maybeAutoCompact` uses the plain total-ratio
        // gate (the fixture default of 8,192 is compact tier, which gates
        // on the compressible ratio instead); near-zero threshold so the
        // gate fires on every iteration.
        let model = LLMModel(
            id: "fake-model-1", displayName: "Fake Model",
            supportsThinking: false, supportsTools: true,
            maxContextTokens: 200_000
        )
        let provider = FakeLLMProvider(model: model)
        let llmRegistry = LLMProviderRegistry()
        await llmRegistry.register(provider)
        let toolRegistry = ToolRegistry()
        let compactor = OrchestrationFixtures.makeCompactor(
            database: database, llmRegistry: llmRegistry, clock: clock, idGenerator: idGen
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
            autoCompactEnabled: true,
            autoCompactThreshold: 0.000_001
        )

        // 6 seeded rows + the new user row = 7 at iteration 1, so the
        // first compaction pass has history beyond the kept tail to
        // summarize.
        for index in 1...3 {
            try await messageRepo.save(MessageRecord(
                id: "seed-u\(index)", conversationId: conversation.id, role: .user,
                content: "seeded user \(index)", createdAt: clock.now()
            ))
            try await messageRepo.save(MessageRecord(
                id: "seed-a\(index)", conversationId: conversation.id, role: .assistant,
                content: "seeded reply \(index)", createdAt: clock.now()
            ))
        }

        // Script order is the loop's consumption order:
        //   1. iteration-1 compaction summary
        //   2. turn 1: a 4-parallel-call batch
        //   3. iteration-2 compaction summary (the mid-loop pass under test)
        //   4. the follow-up turn after tool results
        await provider.enqueue([
            .messageStart(id: "sum-1", model: "fake-model-1"),
            .textDelta(index: 0, text: "Summary one: earlier seeded chatter."),
            .messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 5)),
        ])
        await provider.enqueue([
            .messageStart(id: "m1", model: "fake-model-1"),
            .textDelta(index: 0, text: "running four lookups"),
            .toolUse(index: 0, id: "tc-1", name: toolID, input: .object([:]), signature: nil),
            .toolUse(index: 1, id: "tc-2", name: toolID, input: .object([:]), signature: nil),
            .toolUse(index: 2, id: "tc-3", name: toolID, input: .object([:]), signature: nil),
            .toolUse(index: 3, id: "tc-4", name: toolID, input: .object([:]), signature: nil),
            .messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 5)),
        ])
        await provider.enqueue([
            .messageStart(id: "sum-2", model: "fake-model-1"),
            .textDelta(index: 0, text: "Summary two: the user asked for four lookups."),
            .messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 5)),
        ])
        await provider.enqueue([
            .messageStart(id: "m2", model: "fake-model-1"),
            .textDelta(index: 0, text: "all four came back fine"),
            .messageComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 5)),
        ])

        let executor = FakeToolExecutor(toolID: toolID)
        await executor.setResult(ToolResult(toolID: toolID, content: "ok", isError: false))
        await toolRegistry.register(ToolRegistration(tool: makeTool(id: toolID), execution: .local(executor)))

        let stream = await session.send(text: "look up four things", model: model)
        _ = await collect(stream)
        await session.waitUntilFinished()

        // Two compaction passes ran; the live checkpoint is iteration 2's,
        // landed just before the user turn that prompted the 4-call batch
        // (not the issuing assistant row, not a result row) so the kept
        // window opens user-first.
        let live = try #require(await checkpointRepo.liveCheckpoint(for: conversation.id))
        #expect(live.summary.contains("Summary two"))
        #expect(live.uptoMessageId == "seed-a3")

        // The follow-up request (the last captured) is pair-complete and
        // user-first: the prompting user turn and the assistant turn with
        // all four toolUse blocks survived the checkpoint verbatim, each
        // call with its real result — and no synthesized "interrupted"
        // repair text anywhere.
        let request = try #require(await provider.capturedRequests().last)
        let firstNonSystem = try #require(request.messages.first { $0.role != .system })
        #expect(firstNonSystem.role == .user)
        let firstTexts = firstNonSystem.content.compactMap { block -> String? in
            if case .text(let value) = block { return value }
            return nil
        }
        #expect(firstTexts.contains { $0.contains("look up four things") })
        var toolUseIDs: [String] = []
        var resultsByID: [String: String] = [:]
        for message in request.messages {
            for block in message.content {
                if case .toolUse(let id, _, _, _) = block { toolUseIDs.append(id) }
                if case .toolResult(let id, let content, _) = block { resultsByID[id] = content }
            }
        }
        #expect(toolUseIDs.sorted() == ["tc-1", "tc-2", "tc-3", "tc-4"])
        #expect(resultsByID.keys.sorted() == ["tc-1", "tc-2", "tc-3", "tc-4"])
        #expect(resultsByID.values.allSatisfy { $0 == "ok" })
        let allText = request.messages.flatMap(\.content).compactMap { block -> String? in
            if case .text(let value) = block { return value }
            return nil
        }.joined(separator: "\n")
        #expect(!allText.contains("interrupted"))
        #expect(allText.contains("Summary two"))
    }

    /// Audit P1-6 regression: two sequential assistant turns calling the *same
    /// id-less tool* (the provider supplied no id, so the reducer emits
    /// `id == name`) must persist as two distinct `ToolCallRecord` rows. Before
    /// the fix the GRDB upsert re-parented the first row to the second turn's
    /// message, so turn 1 lost its `toolUse` in projection while its
    /// `tool_result` row survived — an orphaned result strict providers reject.
    @Test func idlessToolCallsAcrossTurnsPersistAsDistinctRowsAndKeepEarlierToolUse() async throws {
        let toolID = "get_weather"
        let setup = try await makeSetup(scripts: [
            // Turn 1: id-less call (id == name), as the Gemini reducer emits.
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .toolUse(index: 0, id: toolID, name: toolID, input: .object(["c": .string("Paris")]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
            // Turn 2: the SAME id-less call again — the cross-turn collision.
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .toolUse(index: 0, id: toolID, name: toolID, input: .object(["c": .string("London")]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
            // Turn 3: finish plainly.
            [
                .messageStart(id: "m3", model: "fake-model-1"),
                .textDelta(index: 0, text: "done"),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
        ])
        let executor = FakeToolExecutor(toolID: toolID)
        await executor.setResult(ToolResult(toolID: toolID, content: "ok", isError: false))
        await setup.toolRegistry.register(ToolRegistration(tool: makeTool(id: toolID), execution: .local(executor)))

        _ = await collect(await setup.session.send(text: "weather twice", model: setup.model))
        await setup.session.waitUntilFinished()

        // Two distinct rows survive — no upsert re-parent. Both id-less, so both
        // got a locally-minted, marked, unique PK. (fetchByConversation already
        // orders createdAt ASC, rowid ASC; the assertions below don't depend on
        // order anyway.)
        let calls = try await setup.toolCallRepo.fetchByConversation(setup.conversation.id)
        #expect(calls.count == 2)
        #expect(Set(calls.map(\.id)).count == 2)
        #expect(calls.allSatisfy { $0.toolName == toolID })
        #expect(calls.allSatisfy { ToolCallRecord.isLocallyMintedID($0.id) })
        #expect(calls[0].messageId != calls[1].messageId)

        // The final assembling request (turn 3) carries BOTH assistant tool
        // turns, each with its own toolUse: turn 1 did not lose its call, and
        // the two wire ids are distinct (strict-provider duplicate-id safety).
        let lastRequest = try #require(await setup.provider.capturedRequests().last)
        var toolUseIDs: [String] = []
        for message in lastRequest.messages {
            for block in message.content {
                if case .toolUse(let id, _, _, _) = block { toolUseIDs.append(id) }
            }
        }
        #expect(toolUseIDs.count == 2)
        #expect(Set(toolUseIDs).count == 2)
    }

    /// The persist seam also disambiguates the *empty-string* id-less shape (the
    /// Anthropic reducer emits `block.id ?? ""`), not just Gemini's `id == name`
    /// fallback — an empty PK would collide across turns and produce an empty
    /// `tool_use` id on the wire. Defensive: Anthropic supplies real ids in
    /// practice, but the guard closes the same bug class for every provider.
    @Test func emptyIDlessToolCallGetsALocallyMintedPK() async throws {
        let toolID = "lookup"
        let setup = try await makeSetup(scripts: [
            [
                .messageStart(id: "m1", model: "fake-model-1"),
                .toolUse(index: 0, id: "", name: toolID, input: .object([:]), signature: nil),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
            [
                .messageStart(id: "m2", model: "fake-model-1"),
                .textDelta(index: 0, text: "done"),
                .messageComplete(usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
            ],
        ])
        let executor = FakeToolExecutor(toolID: toolID)
        await executor.setResult(ToolResult(toolID: toolID, content: "ok", isError: false))
        await setup.toolRegistry.register(ToolRegistration(tool: makeTool(id: toolID), execution: .local(executor)))

        _ = await collect(await setup.session.send(text: "look it up", model: setup.model))
        await setup.session.waitUntilFinished()

        let calls = try await setup.toolCallRepo.fetchByConversation(setup.conversation.id)
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(!call.id.isEmpty)
        #expect(ToolCallRecord.isLocallyMintedID(call.id))
        #expect(call.toolName == toolID)
        // The result row paired against the minted PK (not the empty original).
        let rows = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id)
        let toolRow = try #require(rows.first { $0.role == .tool })
        #expect(toolRow.toolCallId == call.id)
    }
}
