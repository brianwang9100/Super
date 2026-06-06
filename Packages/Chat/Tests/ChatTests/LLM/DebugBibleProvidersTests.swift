#if DEBUG
import Core
import Foundation
import Testing

@testable import Chat

/// Tests for the DEBUG-only Bible-tool debug providers: `DebugBibleTarget`
/// parsing precedence, the canned `bible.annotate` / `bible.note` tool calls
/// each provider emits, the loop-termination guard that stops them annotating
/// forever, and an end-to-end run through `ChatSession`'s tool loop against a
/// fake `bible.annotate` / `bible.note` executor (the real Bible tools are
/// covered by the Bible package's own suite — Chat can't import Bible).
@Suite("Debug Bible providers")
struct DebugBibleProvidersTests {

    // MARK: - DebugBibleTarget.parse

    @Test func headlessReferenceIDResolvesVerseTarget() {
        let messages = [Self.dispatcherMessage(referenceID: "verse:ROM:8:28:30", kind: "verseRange")]
        let target = DebugBibleTarget.parse(from: messages)
        #expect(target == DebugBibleTarget(
            target: "verse", bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30
        ))
    }

    @Test func headlessReferenceIDResolvesChapterTarget() {
        let messages = [Self.dispatcherMessage(referenceID: "chapter:ROM:8", kind: "chapter")]
        let target = DebugBibleTarget.parse(from: messages)
        #expect(target == DebugBibleTarget(
            target: "chapter", bookId: "ROM", chapterNumber: 8, verseStart: nil, verseEnd: nil
        ))
    }

    @Test func headlessReferenceIDResolvesBookTarget() {
        let messages = [Self.dispatcherMessage(referenceID: "book:ROM", kind: "book")]
        let target = DebugBibleTarget.parse(from: messages)
        #expect(target == DebugBibleTarget(
            target: "book", bookId: "ROM", chapterNumber: nil, verseStart: nil, verseEnd: nil
        ))
    }

    @Test func freeTextVerseRangeResolvesViaBookIndex() {
        let messages = [LLMMessage(role: .user, text: "please annotate Romans 8:28-30 for me")]
        let target = DebugBibleTarget.parse(from: messages)
        #expect(target == DebugBibleTarget(
            target: "verse", bookId: "ROM", chapterNumber: 8, verseStart: 28, verseEnd: 30
        ))
    }

    @Test func freeTextSingleVerseSetsEqualStartAndEnd() {
        let messages = [LLMMessage(role: .user, text: "note on John 3:16")]
        let target = DebugBibleTarget.parse(from: messages)
        #expect(target == DebugBibleTarget(
            target: "verse", bookId: "JHN", chapterNumber: 3, verseStart: 16, verseEnd: 16
        ))
    }

    @Test func freeTextChapterOnlyResolvesChapterTarget() {
        let messages = [LLMMessage(role: .user, text: "annotate Psalm 23")]
        let target = DebugBibleTarget.parse(from: messages)
        #expect(target == DebugBibleTarget(
            target: "chapter", bookId: "PSA", chapterNumber: 23, verseStart: nil, verseEnd: nil
        ))
    }

    @Test func noRecognisableReferenceFallsBackToJohn316() {
        let messages = [LLMMessage(role: .user, text: "do something useful")]
        let target = DebugBibleTarget.parse(from: messages)
        #expect(target == DebugBibleTarget(
            target: "verse", bookId: "JHN", chapterNumber: 3, verseStart: 16, verseEnd: 16
        ))
    }

    @Test func freeTextPicksTheEarliestBookNotTheLongestSpelling() {
        // Longest-first iteration must not let a later, longer book name win
        // over the one the user actually cited first.
        let messages = [LLMMessage(role: .user, text: "annotate John 3:16 — compare with 1 Corinthians")]
        let target = DebugBibleTarget.parse(from: messages)
        #expect(target == DebugBibleTarget(
            target: "verse", bookId: "JHN", chapterNumber: 3, verseStart: 16, verseEnd: 16
        ))
    }

    @Test func freeTextIgnoresNumbersNotAdjacentToTheBook() {
        // A number elsewhere in the sentence must not be read as a citation;
        // a bare book mention resolves to the whole-book target.
        let messages = [LLMMessage(role: .user, text: "annotate Romans, the meeting is at 8:30")]
        let target = DebugBibleTarget.parse(from: messages)
        #expect(target == DebugBibleTarget(
            target: "book", bookId: "ROM", chapterNumber: nil, verseStart: nil, verseEnd: nil
        ))
    }

    // MARK: - Provider stream: tool call

    @Test func annotateProviderEmitsBibleAnnotateToolCallWithMultipleCategories() async throws {
        let provider = DebugAnnotateLLMProvider(id: "p")
        let model = try #require(provider.supportedModels.first)
        let events = try await Self.collect(
            provider, messages: [LLMMessage(role: .user, text: "annotate Romans 8:28-30")], model: model
        )

        let call = try #require(Self.firstToolUse(in: events))
        #expect(call.name == "bible.annotate")
        let input = try #require(Self.object(call.input))
        #expect(input["target"] == .string("verse"))
        #expect(input["bookId"] == .string("ROM"))
        #expect(input["chapterNumber"] == .int(8))
        #expect(input["verseStart"] == .int(28))
        #expect(input["verseEnd"] == .int(30))

        guard case .array(let entries) = input["entries"] else {
            Issue.record("expected entries array, got \(String(describing: input["entries"]))")
            return
        }
        // Multiple cards spanning distinct categories.
        #expect(entries.count >= 2)
        let categories = entries.compactMap { entry -> String? in
            guard case .object(let dict) = entry, case .string(let c)? = dict["category"] else { return nil }
            return c
        }
        #expect(Set(categories).count == entries.count)
        // The verse target includes a `reference` card whose body is a bare
        // citation (the tool renders it as a navigation link).
        #expect(categories.contains("reference"))
    }

    @Test func noteProviderEmitsBibleNoteCreateToolCall() async throws {
        let provider = DebugNoteLLMProvider(id: "p")
        let model = try #require(provider.supportedModels.first)
        let events = try await Self.collect(
            provider, messages: [LLMMessage(role: .user, text: "note on John 3:16")], model: model
        )

        let call = try #require(Self.firstToolUse(in: events))
        #expect(call.name == "bible.note")
        let input = try #require(Self.object(call.input))
        #expect(input["action"] == .string("create"))
        #expect(input["target"] == .string("verse"))
        #expect(input["bookId"] == .string("JHN"))
        #expect(input["chapterNumber"] == .int(3))
        #expect(input["verseStart"] == .int(16))
        #expect(input["verseEnd"] == .int(16))
        if case .string(let body)? = input["body"] {
            #expect(!body.isEmpty)
        } else {
            Issue.record("expected non-empty body string")
        }
    }

    @Test func readProviderEmitsBibleReadToolCallForVerseRange() async throws {
        let provider = DebugReadLLMProvider(id: "p")
        let model = try #require(provider.supportedModels.first)
        let events = try await Self.collect(
            provider, messages: [LLMMessage(role: .user, text: "read Romans 8:28-30")], model: model
        )

        let call = try #require(Self.firstToolUse(in: events))
        #expect(call.name == "bible.read")
        let input = try #require(Self.object(call.input))
        #expect(input["book"] == .string("ROM"))
        #expect(input["chapter"] == .int(8))
        #expect(input["startVerse"] == .int(28))
        #expect(input["endVerse"] == .int(30))
        // No translation argument → the tool uses the current selection.
        #expect(input["translation"] == nil)
    }

    @Test func readProviderReadsWholeChapterForAChapterReference() async throws {
        let provider = DebugReadLLMProvider(id: "p")
        let model = try #require(provider.supportedModels.first)
        let events = try await Self.collect(
            provider, messages: [LLMMessage(role: .user, text: "read Psalm 23")], model: model
        )

        let call = try #require(Self.firstToolUse(in: events))
        let input = try #require(Self.object(call.input))
        #expect(input["book"] == .string("PSA"))
        #expect(input["chapter"] == .int(23))
        // No verse bounds → whole chapter.
        #expect(input["startVerse"] == nil)
        #expect(input["endVerse"] == nil)
    }

    @Test func readProviderDefaultsABareBookReferenceToChapterOne() async throws {
        let provider = DebugReadLLMProvider(id: "p")
        let model = try #require(provider.supportedModels.first)
        let events = try await Self.collect(
            provider, messages: [LLMMessage(role: .user, text: "read Romans")], model: model
        )

        let call = try #require(Self.firstToolUse(in: events))
        let input = try #require(Self.object(call.input))
        #expect(input["book"] == .string("ROM"))
        // bible.read requires a chapter; a whole-book reference defaults to 1.
        #expect(input["chapter"] == .int(1))
        #expect(input["startVerse"] == nil)
    }

    // MARK: - Provider stream: loop termination

    @Test func annotateProviderStopsAfterToolResultTurn() async throws {
        let provider = DebugAnnotateLLMProvider(id: "p")
        let model = try #require(provider.supportedModels.first)
        let events = try await Self.collect(provider, messages: Self.afterToolRanMessages(), model: model)

        #expect(Self.firstToolUse(in: events) == nil)
        let hasText = events.contains { if case .textDelta = $0 { return true } else { return false } }
        #expect(hasText)
    }

    @Test func noteProviderStopsAfterToolResultTurn() async throws {
        let provider = DebugNoteLLMProvider(id: "p")
        let model = try #require(provider.supportedModels.first)
        let events = try await Self.collect(provider, messages: Self.afterToolRanMessages(), model: model)

        #expect(Self.firstToolUse(in: events) == nil)
        let hasText = events.contains { if case .textDelta = $0 { return true } else { return false } }
        #expect(hasText)
    }

    @Test func readProviderStopsAfterToolResultTurn() async throws {
        let provider = DebugReadLLMProvider(id: "p")
        let model = try #require(provider.supportedModels.first)
        let events = try await Self.collect(provider, messages: Self.afterToolRanMessages(), model: model)

        #expect(Self.firstToolUse(in: events) == nil)
        let hasText = events.contains { if case .textDelta = $0 { return true } else { return false } }
        #expect(hasText)
    }

    /// Regression: a fresh user turn after an *earlier* tool result (e.g. the
    /// user ran a debug note, then switched to the annotate model in the same
    /// conversation) must still fire a new tool call — only a *trailing* tool
    /// result (mid-loop re-invocation) suppresses it.
    @Test func annotateProviderStillCallsToolWhenEarlierToolResultPrecedesNewUserTurn() async throws {
        let provider = DebugAnnotateLLMProvider(id: "p")
        let model = try #require(provider.supportedModels.first)
        let messages = Self.afterToolRanMessages() + [LLMMessage(role: .user, text: "annotate 1 Peter 2:6")]
        let events = try await Self.collect(provider, messages: messages, model: model)

        let call = try #require(Self.firstToolUse(in: events))
        #expect(call.name == "bible.annotate")
        let input = try #require(Self.object(call.input))
        #expect(input["target"] == .string("verse"))
        #expect(input["bookId"] == .string("1PE"))
        #expect(input["chapterNumber"] == .int(2))
        #expect(input["verseStart"] == .int(6))
    }

    // MARK: - End-to-end through ChatSession's tool loop

    @Test func annotateProviderDrivesOneToolCallThroughSessionThenStops() async throws {
        let provider = DebugAnnotateLLMProvider(id: "debug-annotate-1")
        let setup = try await Self.makeSession(provider: provider)
        let executor = FakeToolExecutor(toolID: "bible.annotate")
        await executor.setResult(ToolResult(toolID: "bible.annotate", content: "ok"))
        await setup.toolRegistry.register(ToolRegistration(
            tool: Self.tool(id: "bible.annotate"), execution: .local(executor)
        ))

        let stream = await setup.session.send(text: "annotate Romans 8:28-30", model: setup.model)
        _ = await Self.drain(stream)
        await setup.session.waitUntilFinished()

        // Tool ran exactly once with the parsed verse target.
        #expect(await executor.executionCount() == 1)
        let input = try #require(await executor.capturedInputs().first)
        #expect(input["target"] == .string("verse"))
        #expect(input["bookId"] == .string("ROM"))
        #expect(input["verseStart"] == .int(28))
        // Loop terminated: user → assistant(toolUse) → tool → assistant(text).
        let roles = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id).map(\.role)
        #expect(roles == [.user, .assistant, .tool, .assistant])
    }

    @Test func noteProviderDrivesOneToolCallThroughSession() async throws {
        let provider = DebugNoteLLMProvider(id: "debug-note-1")
        let setup = try await Self.makeSession(provider: provider)
        let executor = FakeToolExecutor(toolID: "bible.note")
        await executor.setResult(ToolResult(toolID: "bible.note", content: "ok"))
        await setup.toolRegistry.register(ToolRegistration(
            tool: Self.tool(id: "bible.note"), execution: .local(executor)
        ))

        let stream = await setup.session.send(text: "note on John 3:16", model: setup.model)
        _ = await Self.drain(stream)
        await setup.session.waitUntilFinished()

        #expect(await executor.executionCount() == 1)
        let input = try #require(await executor.capturedInputs().first)
        #expect(input["action"] == .string("create"))
        #expect(input["bookId"] == .string("JHN"))
        let roles = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id).map(\.role)
        #expect(roles == [.user, .assistant, .tool, .assistant])
    }

    @Test func readProviderDrivesOneToolCallThroughSession() async throws {
        let provider = DebugReadLLMProvider(id: "debug-read-1")
        let setup = try await Self.makeSession(provider: provider)
        let executor = FakeToolExecutor(toolID: "bible.read")
        await executor.setResult(ToolResult(toolID: "bible.read", content: "John 3:16 (KJV)\n\n16. ..."))
        await setup.toolRegistry.register(ToolRegistration(
            tool: Self.tool(id: "bible.read"), execution: .local(executor)
        ))

        let stream = await setup.session.send(text: "read John 3:16-17", model: setup.model)
        _ = await Self.drain(stream)
        await setup.session.waitUntilFinished()

        #expect(await executor.executionCount() == 1)
        let input = try #require(await executor.capturedInputs().first)
        #expect(input["book"] == .string("JHN"))
        #expect(input["chapter"] == .int(3))
        #expect(input["startVerse"] == .int(16))
        #expect(input["endVerse"] == .int(17))
        let roles = try await setup.messageRepo.fetchAll(conversationId: setup.conversation.id).map(\.role)
        #expect(roles == [.user, .assistant, .tool, .assistant])
    }

    // MARK: - Helpers

    /// A user turn shaped like `BibleAnnotateDispatcher.prompt` — the headless
    /// verse-tap "Add annotation" path.
    private static func dispatcherMessage(referenceID: String, kind: String) -> LLMMessage {
        LLMMessage(role: .user, text: """
        Annotate this scripture target.

        Target kind: \(kind)
        Reference id: \(referenceID)
        Display: Romans 8:28-30 (WEB)
        Citation: Romans 8:28-30 (WEB)

        Call `bible.annotate` once with arguments matching this target, then end the turn.
        """)
    }

    /// A turn-loop history where the tool has already run — the provider must
    /// emit plain text (no further tool call) so the loop ends.
    private static func afterToolRanMessages() -> [LLMMessage] {
        [
            LLMMessage(role: .user, text: "annotate Romans 8:28-30"),
            LLMMessage(role: .assistant, content: [.toolUse(id: "tc-1", name: "bible.annotate", input: .object([:]), signature: nil)]),
            LLMMessage(role: .tool, content: [.toolResult(toolUseID: "tc-1", content: "ok", isError: false)]),
        ]
    }

    private static func collect(
        _ provider: some LLMProvider, messages: [LLMMessage], model: LLMModel
    ) async throws -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []
        for try await event in provider.stream(messages: messages, model: model, tools: [], temperature: 0) {
            events.append(event)
        }
        return events
    }

    private static func firstToolUse(
        in events: [LLMStreamEvent]
    ) -> (id: String, name: String, input: JSONValue)? {
        for event in events {
            if case .toolUse(_, let id, let name, let input, _) = event { return (id, name, input) }
        }
        return nil
    }

    private static func object(_ value: JSONValue) -> [String: JSONValue]? {
        if case .object(let dict) = value { return dict }
        return nil
    }

    private static func tool(id: String) -> LLMTool {
        LLMTool(id: id, name: id, description: "test", category: .mutation, parameters: [], appletId: "bible")
    }

    private static func drain(_ stream: AsyncStream<ChatEvent>) async -> [ChatEvent] {
        var events: [ChatEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private struct SessionSetup {
        let session: ChatSession
        let messageRepo: GRDBMessageRepository
        let toolRegistry: ToolRegistry
        let conversation: ConversationRecord
        let model: LLMModel
    }

    private static func makeSession(provider: some LLMProvider) async throws -> SessionSetup {
        let database = try ChatDatabase.makeInMemory()
        let messageRepo = GRDBMessageRepository(database: database)
        let toolCallRepo = GRDBToolCallRepository(database: database)
        let checkpointRepo = GRDBCompactionCheckpointRepository(database: database)
        let clock = OrchestrationFixtures.defaultClock()
        let idGen = DeterministicIDGenerator(prefix: "id-", start: 0)
        let conversation = try await OrchestrationFixtures.seedConversation(in: database, clock: clock)

        let llmRegistry = LLMProviderRegistry()
        await llmRegistry.register(provider)
        let model = try #require(provider.supportedModels.first)
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
            autoCompactEnabled: false
        )
        return SessionSetup(
            session: session, messageRepo: messageRepo, toolRegistry: toolRegistry,
            conversation: conversation, model: model
        )
    }
}
#endif
