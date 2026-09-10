import Core
import Foundation
import Testing
@testable import Chat

@Suite("OpenAIResponsesLLMProvider")
struct OpenAIResponsesLLMProviderTests {
    private let baseURL = URL(string: "https://api.openai.com/v1")!
    private let model = LLMModel(
        id: "gpt-5.1",
        displayName: "GPT-5.1",
        supportsThinking: true,
        supportsTools: true,
        maxContextTokens: 200_000
    )

    private func makeProvider(
        http: HTTPClient,
        baseURL: URL? = nil,
        apiKey: String? = "sk-test"
    ) -> OpenAIResponsesLLMProvider {
        OpenAIResponsesLLMProvider(
            id: "cfg-resp",
            displayName: "OpenAI Responses",
            model: model,
            baseURL: baseURL ?? self.baseURL,
            apiKey: apiKey,
            http: http
        )
    }

    private func collect(_ stream: AsyncThrowingStream<LLMStreamEvent, Error>) async throws -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    // MARK: - Stream pipeline

    @Test func plainTextFixtureProducesOrderedTextEventsAndUsage() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-plain"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model, tools: [], temperature: 0.5
        ))

        var iterator = events.makeIterator()
        #expect(iterator.next() == .messageStart(id: "resp_plain", model: "gpt-5.1"))
        #expect(iterator.next() == .contentBlockStart(index: 0, type: .text))
        #expect(iterator.next() == .textDelta(index: 0, text: "Hello"))
        #expect(iterator.next() == .textDelta(index: 0, text: " world"))
        #expect(iterator.next() == .textDelta(index: 0, text: "!"))
        #expect(iterator.next() == .contentBlockStop(index: 0))
        #expect(iterator.next() == .messageComplete(usage: TokenUsage(inputTokens: 9, outputTokens: 3)))
        #expect(iterator.next() == nil)
    }

    @Test func cachedFixtureSurfacesCachedTokensInUsage() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-cached"))
        let provider = makeProvider(http: http)
        let events = try await collect(provider.stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model,
            tools: [],
            temperature: 0.5
        ))

        #expect(events.last == .messageComplete(usage: TokenUsage(
            inputTokens: 1024,
            outputTokens: 3,
            cacheReadInputTokens: 768,
            cacheCreationInputTokens: nil
        )))
    }

    @Test func plainTextFixtureIsChunkingInvariant() async throws {
        let whole = try await collect(makeProvider(http: FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-plain"))).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: model, tools: [], temperature: 0.5
        ))
        let chunked = try await collect(makeProvider(http: FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-plain"), chunkCount: 7)).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: model, tools: [], temperature: 0.5
        ))
        #expect(whole == chunked)
    }

    @Test func reasoningFixtureProducesThinkingThenTextThenUsage() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-reasoning"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "what is 6*7?")],
            model: model, tools: [], temperature: 0.0
        ))

        #expect(events.map(Self.kind) == [
            "messageStart",
            "contentBlockStart(thinking)",
            "thinkingDelta",
            "thinkingDelta",
            "contentBlockStop",
            "contentBlockStart(text)",
            "textDelta",
            "contentBlockStop",
            "messageComplete",
        ])
        let thinkingDeltas = events.compactMap { if case .thinkingDelta(_, let t) = $0 { return t } else { return nil } }
        #expect(thinkingDeltas.joined() == "Let me think. 6 times 7 is 42.")
        let textDeltas = events.compactMap { if case .textDelta(_, let t) = $0 { return t } else { return nil } }
        #expect(textDeltas.joined() == "42")
    }

    @Test func searchFixtureEmitsSearchStartedAndNormalizedCitations() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-search"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "mars news?")],
            model: model, tools: [LLMTool.nativeSearchSentinel], temperature: 0.7
        ))

        #expect(events.contains(.searchStarted(query: "latest mars rover news")))
        let searchIndex = events.firstIndex(of: .searchStarted(query: "latest mars rover news"))
        let firstTextIndex = events.firstIndex { if case .textDelta = $0 { return true } else { return false } }
        #expect(searchIndex != nil && firstTextIndex != nil && searchIndex! < firstTextIndex!)

        let citations = events.flatMap { event -> [SourceCitation] in
            if case .citations(let c) = event { return c } else { return [] }
        }
        #expect(citations.count == 2)
        #expect(citations[0].title == "NASA: Mars Rover")
        #expect(citations[0].url == URL(string: "https://www.nasa.gov/mars-rover")!)
        // The UI owns the host fallback for empty citation titles.
        #expect(citations[1].title == "")
        #expect(citations[0].id != citations[1].id)
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 120, outputTokens: 40)))
    }

    @Test func searchStartedCarriesQueryFromItemEvenWithoutProgressEvents() async throws {
        // Queries arrive on output_item.added. Progress events may be absent or
        // reordered, so they must not lock in an empty query.
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-search-itemonly"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "q")],
            model: model, tools: [LLMTool.nativeSearchSentinel], temperature: 0.5
        ))
        let starts = events.filter { if case .searchStarted = $0 { return true } else { return false } }
        #expect(starts == [.searchStarted(query: "who won the 2026 world cup")])
    }

    @Test func malformedCitationURLSkipsThatCitationWithoutDroppingTheEvent() async throws {
        // Decode URL strings first so a malformed citation cannot discard its siblings.
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-badurl"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "q")], model: model, tools: [], temperature: 0.5
        ))
        let citations = events.flatMap { event -> [SourceCitation] in
            if case .citations(let c) = event { return c } else { return [] }
        }
        #expect(citations.map(\.url) == [URL(string: "https://good.example.com/a")!])
        #expect(events.contains(.textDelta(index: 0, text: "See sources.")))
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 3, outputTokens: 2)))
    }

    @Test func annotationURLDecodesAsStringSoAMalformedValueDoesNotThrow() throws {
        // Decoding as URL would throw and make the provider drop the entire SSE event.
        let json = #"{"type":"response.output_text.annotation.added","item_id":"m","annotation":{"type":"url_citation","url":"https://exa mple.com/a [b]","title":"T","start_index":0,"end_index":1}}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let event = try decoder.decode(OpenAIResponsesStreamEvent.self, from: Data(json.utf8))
        #expect(event.annotation?.title == "T")
        #expect(event.annotation?.url == "https://exa mple.com/a [b]")
    }

    @Test func contentEventsAfterAnSSEErrorAreIgnored() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-error-then-text"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "q")], model: model, tools: [], temperature: 0.5
        ))
        #expect(events.map(Self.kind) == ["messageStart", "error", "messageComplete"])
    }

    @Test func sseErrorAfterAnOpenTextBlockClosesItBeforeTheError() async throws {
        // Close blocks before the error so closeOut() cannot emit a late stop.
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-error-after-text"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "q")], model: model, tools: [], temperature: 0.5
        ))
        #expect(events.suffix(4).map(Self.kind) == ["textDelta", "contentBlockStop", "error", "messageComplete"])
    }

    @Test func transportErrorAfterAnSSEErrorDoesNotDoubleReport() async throws {
        // ChatSession keeps the last error; a transport failure must not overwrite
        // the more specific provider error.
        let http = FakeHTTPClient(
            chunks: [Data(FixtureLoader.load("openai-responses-error-only").utf8)],
            error: HTTPError.badStatus(500, body: "")
        )
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "q")], model: model, tools: [], temperature: 0.5
        ))
        let errors = events.compactMap { event -> LLMError? in
            if case .error(let e) = event { return e } else { return nil }
        }
        #expect(errors == [.providerError(code: "server_error", message: "boom")])
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    @Test func transportErrorWithOpenTextBlockClosesBlockBeforeTheError() async throws {
        let http = FakeHTTPClient(
            chunks: [Data(FixtureLoader.load("openai-responses-partial-text").utf8)],
            error: HTTPError.badStatus(500, body: "")
        )
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "q")], model: model, tools: [], temperature: 0.5
        ))
        #expect(events.suffix(4).map(Self.kind) == ["textDelta", "contentBlockStop", "error", "messageComplete"])
    }

    @Test func transportErrorWithPartialToolCallDoesNotEmitASpuriousDecodingError() async throws {
        // Do not parse partial tool arguments after transport failure: a decoding error
        // would mask the network error because ChatSession keeps the last one.
        let http = FakeHTTPClient(
            chunks: [Data(FixtureLoader.load("openai-responses-partial-toolcall").utf8)],
            error: HTTPError.badStatus(503, body: "")
        )
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "q")], model: model, tools: [], temperature: 0.5
        ))
        let errors = events.compactMap { event -> LLMError? in
            if case .error(let e) = event { return e } else { return nil }
        }
        #expect(errors == [.providerError(code: "503", message: "HTTP 503")])
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    @Test func toolCallFixtureAccumulatesArgumentsAndEmitsToolUse() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-toolcall"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "weather in Paris?")],
            model: model, tools: [], temperature: 0.0
        ))

        let toolUses = events.compactMap { event -> (id: String, name: String, input: JSONValue)? in
            if case .toolUse(_, let id, let name, let input, _) = event { return (id, name, input) }
            return nil
        }
        #expect(toolUses.count == 1)
        #expect(toolUses.first?.id == "call_abc")
        #expect(toolUses.first?.name == "get_weather")
        #expect(toolUses.first?.input == .object(["city": .string("Paris")]))
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 15, outputTokens: 8)))
    }

    // MARK: - Error ordering (messageStart-first contract)

    @Test func sseErrorBeforeAnyContentStillEmitsMessageStartFirst() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-error"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: model, tools: [], temperature: 0.5
        ))
        #expect(events.map(Self.kind) == ["messageStart", "error", "messageComplete"])
        if case .error(.providerError(let code, _)) = events[1] {
            #expect(code == "rate_limit_exceeded")
        } else {
            Issue.record("expected providerError, got \(events[1])")
        }
    }

    @Test func transportFailureBeforeAnySSEStillEmitsMessageStartFirst() async throws {
        let http = FakeHTTPClient(error: HTTPError.badStatus(401, body: ""))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: model, tools: [], temperature: 0.5
        ))
        #expect(events.map(Self.kind) == ["messageStart", "error", "messageComplete"])
        #expect(events[1] == .error(.unauthorized))
    }

    // MARK: - Request shape

    @Test func requestTargetsResponsesEndpointWithBearerAuth() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-plain"))
        _ = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: model, tools: [], temperature: 0.5
        ))
        let request = try #require(http.observed.all.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    }

    @Test func cleartextEndpointOmitsTheKey() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-plain"))
        _ = try await collect(makeProvider(http: http, baseURL: URL(string: "http://insecure.example.com/v1")!).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: model, tools: [], temperature: 0.5
        ))
        let request = try #require(http.observed.all.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - Cache-routing key (host-gated, body field only)

    @Test func promptCacheKeyAttachedForOpenAIHost() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-plain"))
        _ = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model, tools: [], temperature: 0.5,
            options: LLMRequestOptions(conversationCacheKey: "conv-123")
        ))
        #expect(try Self.decodeBody(http)["prompt_cache_key"] as? String == "conv-123")
    }

    @Test func promptCacheKeyAbsentForNonOpenAIHost() async throws {
        let proxy = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-plain"))
        _ = try await collect(makeProvider(http: proxy, baseURL: URL(string: "https://proxy.example.com/v1")!).stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model, tools: [], temperature: 0.5,
            options: LLMRequestOptions(conversationCacheKey: "conv-123")
        ))
        #expect(try Self.decodeBody(proxy)["prompt_cache_key"] == nil)
    }

    @Test func promptCacheKeyAbsentForOpenAIHostWithNoneOptions() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-plain"))
        _ = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: model, tools: [], temperature: 0.5
        ))
        #expect(try Self.decodeBody(http)["prompt_cache_key"] == nil)
    }

    @Test func systemMessageBecomesInstructionsAndUserBecomesInput() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-plain"))
        _ = try await collect(makeProvider(http: http).stream(
            messages: [
                LLMMessage(role: .system, text: "You are terse."),
                LLMMessage(role: .user, text: "hi"),
            ],
            model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        #expect(body["instructions"] as? String == "You are terse.")
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.count == 1)
        #expect(input[0]["type"] as? String == "message")
        #expect(input[0]["role"] as? String == "user")
    }

    @Test func nativeSearchSentinelBecomesWebSearchToolAndIsStrippedFromFunctions() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-plain"))
        let clientTool = LLMTool(
            id: "t1", name: "get_weather", description: "Look up weather",
            category: .query,
            parameters: [LLMToolParameter(name: "city", type: .string, description: "City", isRequired: true)],
            appletId: "chat"
        )
        _ = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model,
            tools: [clientTool, .nativeSearchSentinel],
            temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let tools = try #require(body["tools"] as? [[String: Any]])
        let types = tools.compactMap { $0["type"] as? String }
        #expect(types.contains("web_search"))
        #expect(types.contains("function"))
        let names = tools.compactMap { $0["name"] as? String }
        #expect(names == ["get_weather"])
        #expect(!names.contains(NativeWebSearch.sentinelToolName))
    }

    @Test func userRoleToolUseBlockIsNotEmittedAsAFunctionCall() async throws {
        // Core types allow user tool-use blocks, but the Responses API rejects that shape.
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-plain"))
        let history: [LLMMessage] = [
            LLMMessage(role: .user, content: [
                .text("hi"),
                .toolUse(id: "call_bad", name: "x", input: .object([:]), signature: nil),
            ]),
        ]
        _ = try await collect(makeProvider(http: http).stream(
            messages: history, model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.compactMap { $0["type"] as? String } == ["message"])
    }

    @Test func noToolsOmitsToolsKeyEntirely() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-plain"))
        _ = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        #expect(body["tools"] == nil)
    }

    @Test func temperatureIsClampedToTheProviderRange() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-plain"))
        _ = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: model, tools: [], temperature: 3.0
        ))
        let body = try Self.decodeBody(http)
        #expect(body["temperature"] as? Double == 2.0)
    }

    @Test func toolCallHistoryRoundTripsAsFunctionCallAndOutputItems() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-plain"))
        let history: [LLMMessage] = [
            LLMMessage(role: .user, text: "weather?"),
            LLMMessage(role: .assistant, content: [
                .text("Let me check."),
                .toolUse(id: "call_xyz", name: "get_weather", input: .object(["city": .string("Paris")]), signature: nil),
            ]),
            LLMMessage(role: .tool, content: [
                .toolResult(toolUseID: "call_xyz", content: "18°C and clear", isError: false),
            ]),
            LLMMessage(role: .user, text: "thanks"),
        ]
        _ = try await collect(makeProvider(http: http).stream(
            messages: history, model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let input = try #require(body["input"] as? [[String: Any]])
        let types = input.compactMap { $0["type"] as? String }
        #expect(types == ["message", "message", "function_call", "function_call_output", "message"])

        let assistantContent = input[1]["content"] as? [[String: Any]]
        #expect(assistantContent?.first?["type"] as? String == "output_text")

        let fnCall = input[2]
        let fnOutput = input[3]
        #expect(fnCall["name"] as? String == "get_weather")
        #expect(fnCall["call_id"] as? String == "call_xyz")
        #expect(fnOutput["call_id"] as? String == "call_xyz")
        #expect(fnOutput["output"] as? String == "18°C and clear")
        #expect(fnCall["arguments"] as? String == "{\"city\":\"Paris\"}")
    }

    // MARK: - Tool wire-name sanitization (dot-namespaced tool IDs)

    /// The API rejects dots in function names, so encode local tool IDs for the wire.
    @Test func dotNamespacedToolNameIsSanitizedInToolDefinitions() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-plain"))
        _ = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model, tools: [.dotNamedTimeTool], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["time_now"])
    }

    @Test func dotNamespacedHistoryToolCallEncodesTheSanitizedWireName() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-plain"))
        let history: [LLMMessage] = [
            LLMMessage(role: .user, text: "time?"),
            LLMMessage(role: .assistant, content: [
                .toolUse(id: "call_xyz", name: "time.now", input: .object([:]), signature: nil),
            ]),
            LLMMessage(role: .tool, content: [
                .toolResult(toolUseID: "call_xyz", content: "12:00", isError: false),
            ]),
        ]
        _ = try await collect(makeProvider(http: http).stream(
            messages: history, model: model, tools: [.dotNamedTimeTool], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let input = try #require(body["input"] as? [[String: Any]])
        let fnCall = try #require(input.first { $0["type"] as? String == "function_call" })
        #expect(fnCall["name"] as? String == "time_now")
    }

    @Test func streamedToolCallNameIsRestoredToTheRegistryName() async throws {
        // Restore local IDs before the ToolRegistry exact-match lookup.
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-toolcall-dotname"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "time?")],
            model: model, tools: [.dotNamedTimeTool], temperature: 0.0
        ))
        let names = events.compactMap { event -> String? in
            if case .toolUse(_, _, let name, _, _) = event { return name }
            return nil
        }
        #expect(names == ["time.now"])
    }

    // MARK: - Helpers

    private static func decodeBody(_ http: FakeHTTPClient) throws -> [String: Any] {
        let request = try #require(http.observed.all.first)
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func kind(_ event: LLMStreamEvent) -> String {
        switch event {
        case .messageStart: return "messageStart"
        case .contentBlockStart(_, let type): return "contentBlockStart(\(type.rawValue))"
        case .textDelta: return "textDelta"
        case .thinkingDelta: return "thinkingDelta"
        case .thinkingSignature: return "thinkingSignature"
        case .toolUse: return "toolUse"
        case .contentBlockStop: return "contentBlockStop"
        case .searchStarted: return "searchStarted"
        case .citations: return "citations"
        case .searchSuggestionsHTML: return "searchSuggestionsHTML"
        case .messageComplete: return "messageComplete"
        case .error: return "error"
        }
    }
}

extension LLMTool {
    static var dotNamedTimeTool: LLMTool {
        LLMTool(
            id: "time.now",
            name: "time.now",
            description: "Returns the current time.",
            category: .query,
            parameters: [],
            appletId: "chat"
        )
    }

    static var nativeSearchSentinel: LLMTool {
        LLMTool(
            id: NativeWebSearch.sentinelToolName,
            name: NativeWebSearch.sentinelToolName,
            description: "Enable native web search for this turn.",
            category: .query,
            parameters: [],
            appletId: "chat"
        )
    }
}
