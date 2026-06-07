import Core
import Foundation
import Testing
@testable import Chat

/// End-to-end tests for `GeminiNativeLLMProvider`. Exercises the request shape
/// (URL, `x-goog-api-key` header, `systemInstruction`, `google_search` sentinel,
/// thinking config, tool translation) and the full streaming pipeline by
/// replaying recorded `streamGenerateContent` SSE (Server-Sent Events) fixtures
/// through a fake HTTP client. No real network — ever (per Chat `AGENTS.md`).
///
/// **Stream contract**: every test asserts the stream terminates with
/// `.messageComplete`; failures surface as `.error` events, never throws.
///
/// `LLMTool.nativeSearchSentinel` is defined once in the OpenAI Responses test
/// file (same test module) and reused here.
@Suite("GeminiNativeLLMProvider")
struct GeminiNativeLLMProviderTests {
    private let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!
    private let model = LLMModel(
        id: "gemini-2.5-pro",
        displayName: "Gemini 2.5 Pro",
        supportsThinking: true,
        supportsTools: true,
        maxContextTokens: 1_000_000
    )
    private let nonThinkingModel = LLMModel(
        id: "gemini-2.5-flash-lite",
        displayName: "Gemini 2.5 Flash-Lite",
        supportsThinking: false,
        supportsTools: true,
        maxContextTokens: 1_000_000
    )

    private func makeProvider(
        http: HTTPClient,
        model: LLMModel? = nil,
        baseURL: URL? = nil,
        apiKey: String? = "test-key"
    ) -> GeminiNativeLLMProvider {
        GeminiNativeLLMProvider(
            id: "cfg-gemini",
            displayName: "Gemini",
            model: model ?? self.model,
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
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-plain"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model, tools: [], temperature: 0.5
        ))

        var iterator = events.makeIterator()
        #expect(iterator.next() == .messageStart(id: "resp_plain", model: "gemini-2.5-pro"))
        #expect(iterator.next() == .contentBlockStart(index: 0, type: .text))
        #expect(iterator.next() == .textDelta(index: 0, text: "Hello"))
        #expect(iterator.next() == .textDelta(index: 0, text: " world!"))
        #expect(iterator.next() == .contentBlockStop(index: 0))
        #expect(iterator.next() == .messageComplete(usage: TokenUsage(inputTokens: 12, outputTokens: 3)))
        #expect(iterator.next() == nil)
    }

    /// Chunked delivery must produce the identical event stream — proves the SSE
    /// parser's partial-frame handling holds for Gemini's unnamed-`data:` framing.
    @Test func plainTextFixtureIsChunkingInvariant() async throws {
        let whole = try await collect(makeProvider(http: FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-plain"))).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: model, tools: [], temperature: 0.5
        ))
        let chunked = try await collect(makeProvider(http: FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-plain"), chunkCount: 7)).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: model, tools: [], temperature: 0.5
        ))
        #expect(whole == chunked)
    }

    @Test func thinkingFixtureSwitchesFromThinkingToTextBlock() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-thinking"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "what is 6*7?")],
            model: model, tools: [], temperature: 0.0
        ))

        // The thought part opens a thinking block; the plain text part flips to
        // a fresh text block (distinct normalized index 0 then 1).
        #expect(events.map(Self.kind) == [
            "messageStart",
            "contentBlockStart(thinking)",
            "thinkingDelta",
            "contentBlockStop",
            "contentBlockStart(text)",
            "textDelta",
            "contentBlockStop",
            "messageComplete",
        ])
        #expect(events.contains(.thinkingDelta(index: 0, text: "Let me think")))
        #expect(events.contains(.textDelta(index: 1, text: "42")))
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 20, outputTokens: 10)))
    }

    @Test func searchFixtureEmitsCitationsAndSuggestionsHTML() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-search"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "mars news?")],
            model: model, tools: [.nativeSearchSentinel], temperature: 0.7
        ))

        // Gemini delivers grounding in the final chunk, so `.searchStarted`
        // lands after the answer text (unlike Anthropic's server_tool_use).
        #expect(events.contains(.searchStarted(query: "mars rover news")))
        #expect(events.contains(.textDelta(index: 0, text: "The rover found ice.")))

        let citations = events.flatMap { event -> [SourceCitation] in
            if case .citations(let c) = event { return c } else { return [] }
        }
        #expect(citations.count == 2)
        let nasa = try #require(citations.first)
        #expect(nasa.url == URL(string: "https://www.nasa.gov/mars")!)
        #expect(nasa.title == "NASA Mars")
        // Snippet comes from the grounding support that references chunk 0.
        #expect(nasa.snippet == "The rover found ice.")
        // Gemini citations carry no echo (no per-result blob to round-trip).
        #expect(nasa.providerEcho == nil)
        // Each id is URL + ordinal so a `ForEach` can't collide.
        #expect(citations[1].id == "https://www.space.com/rover#1")
        #expect(citations[1].snippet == nil)

        // The mandatory Search-Suggestions HTML is surfaced unmodified.
        let suggestions = events.compactMap { event -> String? in
            if case .searchSuggestionsHTML(let html) = event { return html } else { return nil }
        }
        #expect(suggestions == ["<div class=\"gsc\">chips</div>"])
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 30, outputTokens: 25)))
    }

    /// The grounding path carries a large `groundingMetadata` JSON in the final
    /// chunk — the shape most likely to expose an SSE partial-frame bug — so it
    /// must be chunking-invariant too.
    @Test func searchFixtureIsChunkingInvariant() async throws {
        let whole = try await collect(makeProvider(http: FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-search"))).stream(
            messages: [LLMMessage(role: .user, text: "mars?")], model: model, tools: [.nativeSearchSentinel], temperature: 0.5
        ))
        let chunked = try await collect(makeProvider(http: FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-search"), chunkCount: 11)).stream(
            messages: [LLMMessage(role: .user, text: "mars?")], model: model, tools: [.nativeSearchSentinel], temperature: 0.5
        ))
        #expect(whole == chunked)
    }

    /// Two grounding chunks pointing at the same URL must yield distinct
    /// `SourceCitation.id`s (URL + ordinal) so a `ForEach` can't collide.
    @Test func sameURLGroundingChunksGetDistinctIDs() async throws {
        let sse = """
        data: {"candidates":[{"content":{"role":"model","parts":[{"text":"x"}]},"finishReason":"STOP","groundingMetadata":{"groundingChunks":[{"web":{"uri":"https://example.com/a","title":"A"}},{"web":{"uri":"https://example.com/a","title":"A again"}}]}}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1},"modelVersion":"gemini-2.5-pro","responseId":"r"}

        """
        let http = FakeHTTPClient(chunks: [Data(sse.utf8)])
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "q")], model: model, tools: [.nativeSearchSentinel], temperature: 0.5
        ))
        let citations = events.flatMap { event -> [SourceCitation] in
            if case .citations(let c) = event { return c } else { return [] }
        }
        #expect(citations.count == 2)
        #expect(citations[0].id == "https://example.com/a#0")
        #expect(citations[1].id == "https://example.com/a#1")
        #expect(Set(citations.map(\.id)).count == 2)
    }

    @Test func toolCallFixtureEmitsToolUseWholeWithNameAsID() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-toolcall"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "weather in Paris?")],
            model: model, tools: [], temperature: 0.0
        ))

        #expect(events.map(Self.kind) == [
            "messageStart", "contentBlockStart(toolUse)", "toolUse", "contentBlockStop", "messageComplete",
        ])
        let toolUses = events.compactMap { event -> (id: String, name: String, input: JSONValue)? in
            if case .toolUse(_, let id, let name, let input, _) = event { return (id, name, input) }
            return nil
        }
        #expect(toolUses.count == 1)
        // Gemini supplies no call id; the function name doubles as the id.
        #expect(toolUses.first?.id == "get_weather")
        #expect(toolUses.first?.name == "get_weather")
        #expect(toolUses.first?.input == .object(["city": .string("Paris")]))
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 15, outputTokens: 8)))
    }

    /// Gemini returns a unique per-call `id` on each `functionCall` (verified
    /// against the live `gemini-3.5-flash` wire body). When the same tool is
    /// called twice in one turn the reducer must surface those distinct ids on
    /// the `.toolUse` events — using the function *name* as the id collapses
    /// both calls onto one identity, which collides the `toolCall` primary key
    /// and traps transcript projection (the bible-"wrath" crash).
    @Test func parallelToolCallsToSameToolGetDistinctServerIDs() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-parallel-toolcalls"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "weather in Paris and London?")],
            model: model, tools: [], temperature: 0.0
        ))
        let toolUses = events.compactMap { event -> (id: String, name: String)? in
            if case .toolUse(_, let id, let name, _, _) = event { return (id, name) }
            return nil
        }
        #expect(toolUses.count == 2)
        #expect(toolUses.map(\.name) == ["get_weather", "get_weather"])
        #expect(toolUses.map(\.id) == ["call-paris", "call-london"])
        #expect(Set(toolUses.map(\.id)).count == 2)
    }

    /// Replaying parallel same-tool calls must round-trip each call's server id
    /// on both the `functionCall` and its matching `functionResponse`, with the
    /// function *name* carried on the response (Gemini matches result→call by
    /// id; `name` is a required `functionResponse` field).
    @Test func parallelSameToolResultsRoundTripWithDistinctIDs() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-plain"))
        let history: [LLMMessage] = [
            LLMMessage(role: .user, text: "weather in Paris and London?"),
            LLMMessage(role: .assistant, content: [
                .toolUse(id: "call-paris", name: "get_weather", input: .object(["city": .string("Paris")]), signature: nil),
                .toolUse(id: "call-london", name: "get_weather", input: .object(["city": .string("London")]), signature: nil),
            ]),
            LLMMessage(role: .tool, content: [
                .toolResult(toolUseID: "call-paris", content: "18C", isError: false),
                .toolResult(toolUseID: "call-london", content: "12C", isError: false),
            ]),
        ]
        _ = try await collect(makeProvider(http: http).stream(
            messages: history, model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let contents = try #require(body["contents"] as? [[String: Any]])

        // Assistant turn: two functionCall parts, each carrying its server id.
        let modelParts = try #require(contents[1]["parts"] as? [[String: Any]])
        let calls = modelParts.compactMap { $0["functionCall"] as? [String: Any] }
        #expect(calls.count == 2)
        #expect(calls.compactMap { $0["id"] as? String } == ["call-paris", "call-london"])
        #expect(calls.allSatisfy { $0["name"] as? String == "get_weather" })

        // Tool results: two functionResponse parts keyed by the matching id,
        // each naming the function.
        let resultParts = try #require(contents[2]["parts"] as? [[String: Any]])
        let responses = resultParts.compactMap { $0["functionResponse"] as? [String: Any] }
        #expect(responses.count == 2)
        #expect(responses.compactMap { $0["id"] as? String } == ["call-paris", "call-london"])
        #expect(responses.allSatisfy { $0["name"] as? String == "get_weather" })
    }

    /// Thinking models attach a `thoughtSignature` to the functionCall part;
    /// the reducer must surface it on the `.toolUse` event so it can be
    /// persisted and replayed (Gemini 400s on a replay that omits it).
    @Test func toolCallCapturesThoughtSignature() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-toolcall-signature"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "weather in Paris?")],
            model: model, tools: [], temperature: 0.0
        ))
        let signature = events.compactMap { event -> String? in
            if case .toolUse(_, _, _, _, let signature) = event { return signature }
            return nil
        }.first
        #expect(signature == "SIG-abc123")
    }

    /// Gemini may deliver the `thoughtSignature` on a separate (empty-text)
    /// part preceding the `functionCall`. The reducer must still attach it to
    /// the tool call rather than dropping it with the content-free part.
    @Test func toolCallCapturesThoughtSignatureFromSeparatePart() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-toolcall-signature-separate"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "weather in Paris?")],
            model: model, tools: [], temperature: 0.0
        ))
        let signature = events.compactMap { event -> String? in
            if case .toolUse(_, _, _, _, let signature) = event { return signature }
            return nil
        }.first
        #expect(signature == "SIG-sep-99")
    }

    /// On replay, the persisted signature must ride the request's functionCall
    /// part as a sibling `thoughtSignature` key — the exact field Gemini
    /// rejected the `bible.annotate` follow-up turn for omitting.
    @Test func replayedToolCallEncodesThoughtSignatureOnFunctionCallPart() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-plain"))
        let history: [LLMMessage] = [
            LLMMessage(role: .user, text: "weather?"),
            LLMMessage(role: .assistant, content: [
                .toolUse(
                    id: "get_weather", name: "get_weather",
                    input: .object(["city": .string("Paris")]), signature: "SIG-xyz"
                ),
            ]),
            LLMMessage(role: .tool, content: [
                .toolResult(toolUseID: "get_weather", content: "18C clear", isError: false),
            ]),
        ]
        _ = try await collect(makeProvider(http: http).stream(
            messages: history, model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let contents = try #require(body["contents"] as? [[String: Any]])
        let modelParts = try #require(contents[1]["parts"] as? [[String: Any]])
        // The functionCall part carries the thoughtSignature as a sibling key.
        let callPart = try #require(modelParts.first { $0["functionCall"] != nil })
        #expect(callPart["thoughtSignature"] as? String == "SIG-xyz")
    }

    // MARK: - Error ordering (messageStart-first contract)

    @Test func streamedErrorBeforeAnyContentStillEmitsMessageStartFirst() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-error-only"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: model, tools: [], temperature: 0.5
        ))
        #expect(events.map(Self.kind) == ["messageStart", "error", "messageComplete"])
        let errors = events.compactMap { event -> LLMError? in
            if case .error(let e) = event { return e } else { return nil }
        }
        #expect(errors == [.providerError(code: "RESOURCE_EXHAUSTED", message: "Resource exhausted")])
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    @Test func streamedErrorAfterAnOpenTextBlockClosesItBeforeTheError() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-error-after-text"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "q")], model: model, tools: [], temperature: 0.5
        ))
        #expect(events.suffix(4).map(Self.kind) == ["textDelta", "contentBlockStop", "error", "messageComplete"])
        let errors = events.compactMap { event -> LLMError? in
            if case .error(let e) = event { return e } else { return nil }
        }
        #expect(errors == [.providerError(code: "INTERNAL", message: "boom")])
    }

    @Test func transportErrorWithOpenTextBlockClosesItAndReportsTheError() async throws {
        // A text block is open when the transport drops: the open block's start
        // is balanced with a stop, then the transport error is reported.
        let http = FakeHTTPClient(
            chunks: [Data(FixtureLoader.load("gemini-open-text").utf8)],
            error: HTTPError.badStatus(503, body: "")
        )
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "q")], model: model, tools: [], temperature: 0.5
        ))
        #expect(events.map(Self.kind) == [
            "messageStart", "contentBlockStart(text)", "textDelta", "contentBlockStop", "error", "messageComplete",
        ])
        let errors = events.compactMap { event -> LLMError? in
            if case .error(let e) = event { return e } else { return nil }
        }
        #expect(errors == [.providerError(code: "503", message: "HTTP 503")])
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 7, outputTokens: 0)))
    }

    @Test func transportErrorAfterAStreamedErrorDoesNotDoubleReport() async throws {
        // A streamed error envelope fires, then the transport also drops. The
        // catch must not yield a second, less-specific error over the
        // already-surfaced one (`ChatSession` keeps the last).
        let http = FakeHTTPClient(
            chunks: [Data(FixtureLoader.load("gemini-error-only").utf8)],
            error: HTTPError.badStatus(500, body: "")
        )
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "q")], model: model, tools: [], temperature: 0.5
        ))
        let errors = events.compactMap { event -> LLMError? in
            if case .error(let e) = event { return e } else { return nil }
        }
        #expect(errors == [.providerError(code: "RESOURCE_EXHAUSTED", message: "Resource exhausted")])
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    @Test func unsupportedModelYieldsErrorBeforeCompletion() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-plain"))
        let unknown = LLMModel(id: "gemini-not-configured", displayName: "Nope", maxContextTokens: 1_000_000)
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: unknown, tools: [], temperature: 0.5
        ))
        #expect(events.map(Self.kind) == ["messageStart", "error", "messageComplete"])
        let errors = events.compactMap { event -> LLMError? in
            if case .error(let e) = event { return e } else { return nil }
        }
        #expect(errors == [.unsupportedModel("gemini-not-configured")])
    }

    @Test func transportFailureBeforeAnySSEStillEmitsMessageStartFirst() async throws {
        let http = FakeHTTPClient(chunks: [], error: HTTPError.badStatus(401, body: ""))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: model, tools: [], temperature: 0.5
        ))
        #expect(events.map(Self.kind) == ["messageStart", "error", "messageComplete"])
        let errors = events.compactMap { event -> LLMError? in
            if case .error(let e) = event { return e } else { return nil }
        }
        #expect(errors == [.unauthorized])
    }

    // MARK: - Request shape

    @Test func requestTargetsStreamGenerateContentWithGoogleHeader() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-plain"))
        _ = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: model, tools: [], temperature: 0.5
        ))
        let request = try #require(http.observed.all.first)
        #expect(request.url?.absoluteString
            == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:streamGenerateContent?alt=sse")
        // Gemini authenticates with x-goog-api-key, NOT a bearer token.
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    }

    @Test func cleartextEndpointOmitsTheKey() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-plain"))
        _ = try await collect(makeProvider(http: http, baseURL: URL(string: "http://insecure.example.com/v1beta")!).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: model, tools: [], temperature: 0.5
        ))
        let request = try #require(http.observed.all.first)
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == nil)
    }

    @Test func thinkingModelSendsThinkingConfigAndTemperature() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-plain"))
        _ = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let config = try #require(body["generationConfig"] as? [String: Any])
        #expect(config["temperature"] as? Double == 0.5)
        let thinking = try #require(config["thinkingConfig"] as? [String: Any])
        #expect(thinking["includeThoughts"] as? Bool == true)
    }

    @Test func nonThinkingModelOmitsThinkingConfigAndClampsTemperature() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-plain"))
        _ = try await collect(makeProvider(http: http, model: nonThinkingModel).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: nonThinkingModel, tools: [], temperature: 5.0
        ))
        let body = try Self.decodeBody(http)
        let config = try #require(body["generationConfig"] as? [String: Any])
        #expect(config["thinkingConfig"] == nil)
        // Gemini accepts [0, 2]; out-of-range clamps rather than rejects.
        #expect(config["temperature"] as? Double == 2.0)
    }

    @Test func systemMessageBecomesSystemInstructionAndUserBecomesContent() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-plain"))
        _ = try await collect(makeProvider(http: http).stream(
            messages: [
                LLMMessage(role: .system, text: "You are terse."),
                LLMMessage(role: .user, text: "hi"),
            ],
            model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let systemInstruction = try #require(body["systemInstruction"] as? [String: Any])
        let systemParts = try #require(systemInstruction["parts"] as? [[String: Any]])
        #expect(systemParts[0]["text"] as? String == "You are terse.")
        // The system message must NOT leak into `contents`.
        let contents = try #require(body["contents"] as? [[String: Any]])
        #expect(contents.count == 1)
        #expect(contents[0]["role"] as? String == "user")
        let parts = try #require(contents[0]["parts"] as? [[String: Any]])
        #expect(parts[0]["text"] as? String == "hi")
    }

    @Test func nativeSearchSentinelBecomesGoogleSearchToolAndIsStrippedFromFunctions() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-plain"))
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
        // One tool object carries functionDeclarations; another is google_search.
        let declarations = tools.compactMap { $0["functionDeclarations"] as? [[String: Any]] }.flatMap { $0 }
        let declaredNames = declarations.compactMap { $0["name"] as? String }
        #expect(declaredNames == ["get_weather"])
        #expect(!declaredNames.contains(NativeWebSearch.sentinelToolName))
        // The google_search tool is present as its own `{"google_search":{}}`.
        #expect(tools.contains { $0["google_search"] != nil })
    }

    @Test func arrayParameterDeclaresItemsSchema() async throws {
        // Regression: an array function-declaration parameter must carry `items`
        // — the native generateContent validator rejects the tool with HTTP 400
        // (`properties[entries].items: missing field`) when it's absent.
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-plain"))
        let tool = LLMTool(
            id: "annotate", name: "annotate", description: "writes cards",
            category: .mutation,
            parameters: [
                LLMToolParameter(
                    name: "entries", type: .array, description: "cards", isRequired: true,
                    valueSchema: .object([
                        LLMToolParameter(name: "title", type: .string, description: "t", isRequired: true),
                    ])
                ),
            ],
            appletId: "bible"
        )
        _ = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: model, tools: [tool], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let tools = try #require(body["tools"] as? [[String: Any]])
        let declarations = tools.compactMap { $0["functionDeclarations"] as? [[String: Any]] }.flatMap { $0 }
        let parameters = try #require(declarations.first?["parameters"] as? [String: Any])
        let properties = try #require(parameters["properties"] as? [String: Any])
        let entries = try #require(properties["entries"] as? [String: Any])
        #expect(entries["type"] as? String == "array")
        let items = try #require(entries["items"] as? [String: Any])
        #expect(items["type"] as? String == "object")
        #expect((items["properties"] as? [String: Any])?["title"] != nil)
    }

    @Test func noToolsOmitsToolsKeyEntirely() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-plain"))
        _ = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        #expect(body["tools"] == nil)
    }

    @Test func toolResultBecomesFunctionResponseOnAUserContent() async throws {
        // Gemini has no tool role: a Core `.tool` message becomes a `user`-role
        // content with a functionResponse part keyed by the function name.
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-plain"))
        let history: [LLMMessage] = [
            LLMMessage(role: .user, text: "weather?"),
            LLMMessage(role: .assistant, content: [
                .text("Let me check."),
                .toolUse(id: "get_weather", name: "get_weather", input: .object(["city": .string("Paris")]), signature: nil),
            ]),
            LLMMessage(role: .tool, content: [
                .toolResult(toolUseID: "get_weather", content: "18C clear", isError: false),
            ]),
        ]
        _ = try await collect(makeProvider(http: http).stream(
            messages: history, model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let contents = try #require(body["contents"] as? [[String: Any]])
        #expect(contents.map { $0["role"] as? String } == ["user", "model", "user"])

        // The assistant turn carries text + a functionCall part.
        let modelParts = try #require(contents[1]["parts"] as? [[String: Any]])
        #expect(modelParts[0]["text"] as? String == "Let me check.")
        let functionCall = try #require(modelParts[1]["functionCall"] as? [String: Any])
        #expect(functionCall["name"] as? String == "get_weather")

        // The tool result rides the trailing user content as a functionResponse.
        let resultParts = try #require(contents[2]["parts"] as? [[String: Any]])
        let functionResponse = try #require(resultParts[0]["functionResponse"] as? [String: Any])
        #expect(functionResponse["name"] as? String == "get_weather")
        let response = try #require(functionResponse["response"] as? [String: Any])
        #expect(response["result"] as? String == "18C clear")
    }

    @Test func searchResultBlockIsIgnoredForGemini() async throws {
        // Gemini grounding needs no per-turn echo, so a replayed `.searchResult`
        // block (Anthropic's carrier) produces no extra content — only the text.
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-plain"))
        let cited = SourceCitation(id: "c1", title: "T", url: URL(string: "https://example.com/a")!)
        let history: [LLMMessage] = [
            LLMMessage(role: .assistant, content: [
                .searchResult([cited]),
                .text("answer"),
            ]),
            LLMMessage(role: .user, text: "next"),
        ]
        _ = try await collect(makeProvider(http: http).stream(
            messages: history, model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let contents = try #require(body["contents"] as? [[String: Any]])
        let modelParts = try #require(contents[0]["parts"] as? [[String: Any]])
        #expect(modelParts.count == 1)
        #expect(modelParts[0]["text"] as? String == "answer")
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
