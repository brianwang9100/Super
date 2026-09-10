import Core
import Foundation
import Testing
@testable import Chat

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

    /// Gemini cache hits are a subset of prompt tokens, with no write count.
    @Test func cachedFixtureSurfacesCachedContentTokensInUsage() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-cached"))
        let provider = makeProvider(http: http)
        let events = try await collect(provider.stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model,
            tools: [],
            temperature: 0.5
        ))

        #expect(events.last == .messageComplete(usage: TokenUsage(
            inputTokens: 2048,
            outputTokens: 3,
            cacheReadInputTokens: 1536,
            cacheCreationInputTokens: nil
        )))
    }

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

        // Gemini delivers grounding in the final chunk, after the answer text.
        #expect(events.contains(.searchStarted(query: "mars rover news")))
        #expect(events.contains(.textDelta(index: 0, text: "The rover found ice.")))

        let citations = events.flatMap { event -> [SourceCitation] in
            if case .citations(let c) = event { return c } else { return [] }
        }
        #expect(citations.count == 2)
        let nasa = try #require(citations.first)
        #expect(nasa.url == URL(string: "https://www.nasa.gov/mars")!)
        #expect(nasa.title == "NASA Mars")
        #expect(nasa.snippet == "The rover found ice.")
        #expect(nasa.providerEcho == nil)
        #expect(citations[1].id == "https://www.space.com/rover#1")
        #expect(citations[1].snippet == nil)

        let suggestions = events.compactMap { event -> String? in
            if case .searchSuggestionsHTML(let html) = event { return html } else { return nil }
        }
        #expect(suggestions == ["<div class=\"gsc\">chips</div>"])
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 30, outputTokens: 25)))
    }

    /// Large final-chunk grounding metadata also exercises partial-frame handling.
    @Test func searchFixtureIsChunkingInvariant() async throws {
        let whole = try await collect(makeProvider(http: FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-search"))).stream(
            messages: [LLMMessage(role: .user, text: "mars?")], model: model, tools: [.nativeSearchSentinel], temperature: 0.5
        ))
        let chunked = try await collect(makeProvider(http: FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-search"), chunkCount: 11)).stream(
            messages: [LLMMessage(role: .user, text: "mars?")], model: model, tools: [.nativeSearchSentinel], temperature: 0.5
        ))
        #expect(whole == chunked)
    }

    /// Duplicate URLs need ordinal IDs to avoid ForEach collisions.
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
        // This older fixture lacks a call ID, so the function name supplies the fallback.
        #expect(toolUses.first?.id == "get_weather")
        #expect(toolUses.first?.name == "get_weather")
        #expect(toolUses.first?.input == .object(["city": .string("Paris")]))
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 15, outputTokens: 8)))
    }

    /// Reusing the function name for parallel same-tool calls collides the toolCall
    /// primary key and traps transcript projection. Preserve server IDs.
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

    /// Gemini matches results by ID and also requires the function name.
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

        let modelParts = try #require(contents[1]["parts"] as? [[String: Any]])
        let calls = modelParts.compactMap { $0["functionCall"] as? [String: Any] }
        #expect(calls.count == 2)
        #expect(calls.compactMap { $0["id"] as? String } == ["call-paris", "call-london"])
        #expect(calls.allSatisfy { $0["name"] as? String == "get_weather" })

        let resultParts = try #require(contents[2]["parts"] as? [[String: Any]])
        let responses = resultParts.compactMap { $0["functionResponse"] as? [String: Any] }
        #expect(responses.count == 2)
        #expect(responses.compactMap { $0["id"] as? String } == ["call-paris", "call-london"])
        #expect(responses.allSatisfy { $0["name"] as? String == "get_weather" })
    }

    /// Gemini rejects replay without the original thoughtSignature.
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

    /// A signature can arrive on a preceding empty-text part; retain it for the call.
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
        // ChatSession keeps the last error; a transport failure must not overwrite
        // the more specific provider error.
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
        let declarations = tools.compactMap { $0["functionDeclarations"] as? [[String: Any]] }.flatMap { $0 }
        let declaredNames = declarations.compactMap { $0["name"] as? String }
        #expect(declaredNames == ["get_weather"])
        #expect(!declaredNames.contains(NativeWebSearch.sentinelToolName))
        #expect(tools.contains { $0["google_search"] != nil })
    }

    @Test func arrayParameterDeclaresItemsSchema() async throws {
        // Gemini rejects array schemas without items with HTTP 400.
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
        // Gemini has no tool role; results use user content with functionResponse parts.
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

        let modelParts = try #require(contents[1]["parts"] as? [[String: Any]])
        #expect(modelParts[0]["text"] as? String == "Let me check.")
        let functionCall = try #require(modelParts[1]["functionCall"] as? [String: Any])
        #expect(functionCall["name"] as? String == "get_weather")
        #expect(functionCall["id"] == nil)

        let resultParts = try #require(contents[2]["parts"] as? [[String: Any]])
        let functionResponse = try #require(resultParts[0]["functionResponse"] as? [String: Any])
        #expect(functionResponse["name"] as? String == "get_weather")
        #expect(functionResponse["id"] == nil)
        let response = try #require(functionResponse["response"] as? [String: Any])
        #expect(response["result"] as? String == "18C clear")
    }

    /// Local IDs only disambiguate persistence keys. Gemini round-trips server IDs,
    /// so synthetic IDs must stay off both calls and results on the wire.
    @Test func locallyMintedToolCallIDStaysNameOnlyOnTheWire() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("gemini-plain"))
        let minted = ToolCallRecord.locallyMintedID("id-3")
        let history: [LLMMessage] = [
            LLMMessage(role: .assistant, content: [
                .toolUse(id: minted, name: "get_weather", input: .object(["c": .string("Paris")]), signature: nil),
            ]),
            LLMMessage(role: .tool, content: [
                .toolResult(toolUseID: minted, content: "18C", isError: false),
            ]),
        ]
        _ = try await collect(makeProvider(http: http).stream(
            messages: history, model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let contents = try #require(body["contents"] as? [[String: Any]])

        let modelParts = try #require(contents[0]["parts"] as? [[String: Any]])
        let call = try #require(modelParts.first { $0["functionCall"] != nil }?["functionCall"] as? [String: Any])
        #expect(call["name"] as? String == "get_weather")
        #expect(call["id"] == nil)

        let resultParts = try #require(contents[1]["parts"] as? [[String: Any]])
        let resp = try #require(resultParts.first { $0["functionResponse"] != nil }?["functionResponse"] as? [String: Any])
        #expect(resp["name"] as? String == "get_weather")
        #expect(resp["id"] == nil)
    }

    @Test func searchResultBlockIsIgnoredForGemini() async throws {
        // Gemini grounding has no replay echo; omit Anthropic search-result carriers.
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
