import Core
import Foundation
import Testing

@testable import Chat

@Suite("BibleAnnotationStreamGenerator")
struct BibleAnnotationStreamGeneratorTests {
    private let complete = LLMStreamEvent.messageComplete(usage: TokenUsage(inputTokens: 3, outputTokens: 5))

    private func reference(kind: String = "verseRange", sourceID: String = "verse:ROM:8:28:30", appletID: String = "bible") -> RecordReference {
        RecordReference(appletID: appletID, kind: kind, sourceID: sourceID, displayLabel: "Romans 8:28-30", citation: "Romans 8:28-30 (WEB)", snapshot: "Exact selected verse text", id: "request")
    }

    private func setup(provider: any LLMProvider, enabled: Bool = true, registered: Bool = true) async -> (BibleAnnotationStreamGenerator, FakeToolExecutor) {
        let providers = LLMProviderRegistry()
        await providers.register(provider)
        let executor = FakeToolExecutor(toolID: "bible.annotate")
        await executor.setResult(ToolResult(toolID: "bible.annotate", content: "Saved", artifacts: [.init(type: "annotation", id: "annotation")]))
        let tools = ToolRegistry()
        if registered {
            await tools.register(ToolRegistration(
                tool: LLMTool(id: "bible.annotate", name: "bible.annotate", description: "stub", category: .mutation, parameters: [], appletId: "bible"),
                execution: .local(executor), isEnabled: enabled
            ))
        }
        return (BibleAnnotationStreamGenerator(providerRegistry: providers, toolRegistry: tools), executor)
    }

    @Test("partial text is observable before the only save and thinking is excluded")
    func savesOnlyAfterCompletion() async throws {
        let provider = GatedAnnotationProvider()
        let (generator, executor) = await setup(provider: provider)
        let progress = AsyncStream<String>.makeStream()
        let task = Task { await generator.generate(reference: reference()) { progress.continuation.yield($0) } }
        var iterator = progress.stream.makeAsyncIterator()
        provider.continuation.yield(.thinkingDelta(index: 0, text: "private reasoning"))
        provider.continuation.yield(.textDelta(index: 1, text: "First "))
        #expect(await iterator.next() == "First ")
        #expect(await executor.executionCount() == 0)
        provider.continuation.yield(.textDelta(index: 1, text: "paragraph."))
        #expect(await iterator.next() == "First paragraph.")
        #expect(await executor.executionCount() == 0)
        provider.continuation.yield(complete)
        provider.continuation.finish()
        #expect(await task.value == .success(annotationCount: 1))
        #expect(await executor.capturedInputs() == [[
            "target": .string("verse"), "bookId": .string("ROM"), "chapterNumber": .int(8),
            "verseStart": .int(28), "verseEnd": .int(30), "summary": .string("First paragraph."),
        ],])
    }

    @Test("strict completion, tools disabled, and grounding are sent to the selected provider")
    func requestContract() async throws {
        let provider = FakeLLMProvider(model: OrchestrationFixtures.defaultModel())
        await provider.enqueue([.textDelta(index: 0, text: "A note"), complete])
        let (generator, _) = await setup(provider: provider)
        #expect(await generator.generate(reference: reference(), onProgress: { _ in }) == .success(annotationCount: 1))
        let request = try #require(await provider.capturedRequests().first)
        #expect(request.options.requiresCompleteResponse)
        #expect(request.tools.isEmpty)
        #expect(request.messages.last?.content.contains(where: { if case .text(let text) = $0 { return text.contains("Exact selected verse text") }; return false }) == true)
        #expect(BibleAnnotationStreamGenerator.briefing.contains("150–400 words"))
        #expect(BibleAnnotationStreamGenerator.briefing.contains("never a merely"))
        #expect(!BibleAnnotationStreamGenerator.prompt(for: reference()).contains("Call `bible.annotate`"))
    }

    @Test("valid targets become deterministic tool fields", arguments: [
        ("book", "book:ROM", ["target": JSONValue.string("book"), "bookId": .string("ROM")]),
        ("chapter", "chapter:ROM:8", ["target": JSONValue.string("chapter"), "bookId": .string("ROM"), "chapterNumber": .int(8)]),
        ("verseRange", "verse:ROM:8:28:30", ["target": JSONValue.string("verse"), "bookId": .string("ROM"), "chapterNumber": .int(8), "verseStart": .int(28), "verseEnd": .int(30)]),
    ])
    func targetFields(kind: String, sourceID: String, fields: [String: JSONValue]) throws {
        let target = try BibleAnnotationRequestTarget(reference: reference(kind: kind, sourceID: sourceID))
        #expect(target.parameters(summary: "note") == fields.merging(["summary": .string("note")]) { _, new in new })
    }

    @Test("invalid envelopes fail before provider billing", arguments: [
        ("book", "book:"), ("book", "book:ROM:8"), ("chapter", "book:ROM"),
        ("chapter", "chapter:ROM:0"), ("chapter", "chapter:ROM:-1"), ("chapter", "chapter:ROM:+1"),
        ("verseRange", "verse:ROM:8:30:28"), ("verseRange", "verse:ROM:8:28"),
        ("chapterVerses", "chapter:ROM:8"), ("unknown", "book:ROM"),
    ])
    func invalidTargets(kind: String, sourceID: String) async {
        let provider = FakeLLMProvider(model: OrchestrationFixtures.defaultModel())
        let (generator, executor) = await setup(provider: provider)
        let result = await generator.generate(reference: reference(kind: kind, sourceID: sourceID)) { _ in }
        guard case .failure = result else { Issue.record("invalid target succeeded"); return }
        #expect(await provider.capturedRequests().isEmpty)
        #expect(await executor.executionCount() == 0)
    }

    @Test("another applet cannot select a Bible target")
    func rejectsOtherApplet() throws {
        #expect(throws: BibleAnnotationStreamError.invalidTarget) {
            try BibleAnnotationRequestTarget(reference: reference(appletID: "todo"))
        }
    }

    @Test("incomplete, empty, tool, and error responses never save", arguments: [
        [LLMStreamEvent.textDelta(index: 0, text: "Partial")],
        [.thinkingDelta(index: 0, text: "reasoning"), .messageComplete(usage: .init(inputTokens: 0, outputTokens: 0))],
        [.textDelta(index: 0, text: " \n"), .messageComplete(usage: .init(inputTokens: 0, outputTokens: 0))],
        [.textDelta(index: 0, text: "Partial"), .error(.requestFailed("lost")), .messageComplete(usage: .init(inputTokens: 0, outputTokens: 0))],
        [.textDelta(index: 0, text: "Partial"), .toolUse(index: 1, id: "tool", name: "bible.annotate", input: .object([:]), signature: nil), .messageComplete(usage: .init(inputTokens: 0, outputTokens: 0))],
        [.textDelta(index: 0, text: "Partial"), .messageComplete(usage: .init(inputTokens: 0, outputTokens: 0)), .error(.requestFailed("late error"))],
    ])
    func rejectsUnsaveableStreams(events: [LLMStreamEvent]) async {
        let provider = FakeLLMProvider(model: OrchestrationFixtures.defaultModel())
        await provider.enqueue(events)
        let (generator, executor) = await setup(provider: provider)
        guard case .failure = await generator.generate(reference: reference(), onProgress: { _ in }) else {
            Issue.record("unsaveable stream succeeded"); return
        }
        #expect(await executor.executionCount() == 0)
    }

    @Test("missing or disabled writer fails before a provider request", arguments: [false, true])
    func unavailableWriter(registered: Bool) async {
        let provider = FakeLLMProvider(model: OrchestrationFixtures.defaultModel())
        let (generator, _) = await setup(provider: provider, enabled: false, registered: registered)
        guard case .failure = await generator.generate(reference: reference(), onProgress: { _ in }) else {
            Issue.record("unavailable writer succeeded"); return
        }
        #expect(await provider.capturedRequests().isEmpty)
    }

    @Test("transport failure after terminal completion still cannot save")
    func thrownErrorAfterCompletion() async {
        let provider = GatedAnnotationProvider()
        let (generator, executor) = await setup(provider: provider)
        provider.continuation.yield(.textDelta(index: 0, text: "A note"))
        provider.continuation.yield(complete)
        provider.continuation.finish(throwing: LLMError.requestFailed("transport lost"))
        guard case .failure = await generator.generate(reference: reference(), onProgress: { _ in }) else {
            Issue.record("transport failure succeeded"); return
        }
        #expect(await executor.executionCount() == 0)
    }

    @Test("cancellation after partial output never saves")
    func cancellation() async {
        let provider = GatedAnnotationProvider()
        let (generator, executor) = await setup(provider: provider)
        let progress = AsyncStream<Void>.makeStream()
        let task = Task { await generator.generate(reference: reference()) { _ in progress.continuation.yield(()) } }
        provider.continuation.yield(.textDelta(index: 0, text: "Partial"))
        var iterator = progress.stream.makeAsyncIterator()
        await iterator.next()
        task.cancel()
        guard case .failure = await task.value else { Issue.record("cancellation succeeded"); return }
        #expect(await executor.executionCount() == 0)
    }

    @Test("save failures become retryable failures")
    func writeFailure() async {
        let provider = FakeLLMProvider(model: OrchestrationFixtures.defaultModel())
        await provider.enqueue([.textDelta(index: 0, text: "A note"), complete])
        let (generator, executor) = await setup(provider: provider)
        await executor.setError(.scripted("Write failed"))
        #expect(await generator.generate(reference: reference(), onProgress: { _ in }) == .failure(message: "Write failed", classification: .retryable))
    }
}

private struct GatedAnnotationProvider: LLMProvider {
    let id = "gated-annotation"
    let displayName = "Gated annotation"
    let supportedModels = [OrchestrationFixtures.defaultModel()]
    let streamValue: AsyncThrowingStream<LLMStreamEvent, Error>
    let continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation

    init() {
        (streamValue, continuation) = AsyncThrowingStream.makeStream()
    }

    func stream(messages: [LLMMessage], model: LLMModel, tools: [LLMTool], temperature: Double) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        streamValue
    }
}
