import Core
import Foundation
import Testing
@testable import Chat

/// End-to-end tests for `OpenAIResponsesLLMProvider`. Exercises the request
/// shape (URL, auth header, instructions/input split, native-search tool
/// translation) and the full streaming pipeline by replaying recorded
/// Responses SSE (Server-Sent Events) fixtures through a fake HTTP client.
/// No real network — ever (per Chat `AGENTS.md`).
///
/// **Stream contract**: every test asserts the stream terminates with
/// `.messageComplete`; failures surface as `.error` events, never throws.
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

    /// Chunked delivery must produce the identical event stream — proves the
    /// SSE parser's partial-frame handling holds for the Responses framing.
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
        // Thinking and text land on distinct block indices.
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

        // searchStarted carries the query from the web_search_call item and
        // precedes the text block.
        #expect(events.contains(.searchStarted(query: "latest mars rover news")))
        let searchIndex = events.firstIndex(of: .searchStarted(query: "latest mars rover news"))
        let firstTextIndex = events.firstIndex { if case .textDelta = $0 { return true } else { return false } }
        #expect(searchIndex != nil && firstTextIndex != nil && searchIndex! < firstTextIndex!)

        // Two citations, normalized; the second's empty title falls back to host.
        let citations = events.flatMap { event -> [SourceCitation] in
            if case .citations(let c) = event { return c } else { return [] }
        }
        #expect(citations.count == 2)
        #expect(citations[0].title == "NASA: Mars Rover")
        #expect(citations[0].url == URL(string: "https://www.nasa.gov/mars-rover")!)
        // The second annotation has no title; the reducer carries it through
        // empty (the UI owns the host fallback), it does not synthesize one.
        #expect(citations[1].title == "")
        // ids are unique even across same/different urls (url + ordinal).
        #expect(citations[0].id != citations[1].id)
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 120, outputTokens: 40)))
    }

    @Test func toolCallFixtureAccumulatesArgumentsAndEmitsToolUse() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-toolcall"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "weather in Paris?")],
            model: model, tools: [], temperature: 0.0
        ))

        let toolUses = events.compactMap { event -> (id: String, name: String, input: JSONValue)? in
            if case .toolUse(_, let id, let name, let input) = event { return (id, name, input) }
            return nil
        }
        #expect(toolUses.count == 1)
        // The emitted id is the API call_id (so the tool result correlates back).
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
        // Contract: `.messageStart` precedes any other event, even when the
        // provider rejects the turn before a response object exists.
        #expect(events.map(Self.kind) == ["messageStart", "error", "messageComplete"])
        if case .error(.providerError(let code, _)) = events[1] {
            #expect(code == "rate_limit_exceeded")
        } else {
            Issue.record("expected providerError, got \(events[1])")
        }
    }

    @Test func transportFailureBeforeAnySSEStillEmitsMessageStartFirst() async throws {
        // No chunks; the stream finishes by throwing a transport error before
        // any SSE frame arrives — the catch path must flush messageStart first.
        let http = FakeHTTPClient(error: HTTPError.badStatus(401))
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
        // The sentinel never appears as a function tool; it becomes web_search.
        #expect(types.contains("web_search"))
        #expect(types.contains("function"))
        let names = tools.compactMap { $0["name"] as? String }
        #expect(names == ["get_weather"])
        #expect(!names.contains(NativeWebSearch.sentinelToolName))
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
        // Responses accepts [0, 2]; out-of-range clamps rather than rejects.
        #expect(body["temperature"] as? Double == 2.0)
    }

    @Test func toolCallHistoryRoundTripsAsFunctionCallAndOutputItems() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-responses-plain"))
        // A prior assistant turn that called a tool, plus the tool's result —
        // the two must serialize as a `function_call` + `function_call_output`
        // pair correlated by the same call_id.
        let history: [LLMMessage] = [
            LLMMessage(role: .user, text: "weather?"),
            LLMMessage(role: .assistant, content: [
                .text("Let me check."),
                .toolUse(id: "call_xyz", name: "get_weather", input: .object(["city": .string("Paris")])),
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

        // The assistant text block is `output_text`, not `input_text`.
        let assistantContent = input[1]["content"] as? [[String: Any]]
        #expect(assistantContent?.first?["type"] as? String == "output_text")

        // call_id correlates the function_call and its output.
        let fnCall = input[2]
        let fnOutput = input[3]
        #expect(fnCall["name"] as? String == "get_weather")
        #expect(fnCall["call_id"] as? String == "call_xyz")
        #expect(fnOutput["call_id"] as? String == "call_xyz")
        #expect(fnOutput["output"] as? String == "18°C and clear")
        // Arguments serialize as a JSON string per the API.
        #expect(fnCall["arguments"] as? String == "{\"city\":\"Paris\"}")
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
    /// Convenience for tests: the native-web-search sentinel tool.
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
