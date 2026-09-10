import Core
import Foundation
import Testing
@testable import Chat

@Suite("AnthropicNativeLLMProvider")
struct AnthropicNativeLLMProviderTests {
    private let baseURL = URL(string: "https://api.anthropic.com/v1")!
    private let model = LLMModel(
        id: "claude-opus-4-7",
        displayName: "Opus 4.7",
        supportsThinking: true,
        supportsTools: true,
        maxContextTokens: 200_000
    )
    private let nonThinkingModel = LLMModel(
        id: "claude-haiku-4-5",
        displayName: "Haiku 4.5",
        supportsThinking: false,
        supportsTools: true,
        maxContextTokens: 200_000
    )

    private func makeProvider(
        http: HTTPClient,
        model: LLMModel? = nil,
        baseURL: URL? = nil,
        apiKey: String? = "sk-test"
    ) -> AnthropicNativeLLMProvider {
        AnthropicNativeLLMProvider(
            id: "cfg-anthropic",
            displayName: "Claude",
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
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model, tools: [], temperature: 0.5
        ))

        var iterator = events.makeIterator()
        #expect(iterator.next() == .messageStart(id: "msg_plain", model: "claude-opus-4-7"))
        #expect(iterator.next() == .contentBlockStart(index: 0, type: .text))
        #expect(iterator.next() == .textDelta(index: 0, text: "Hello"))
        #expect(iterator.next() == .textDelta(index: 0, text: " world"))
        #expect(iterator.next() == .textDelta(index: 0, text: "!"))
        #expect(iterator.next() == .contentBlockStop(index: 0))
        #expect(iterator.next() == .messageComplete(usage: TokenUsage(inputTokens: 12, outputTokens: 3)))
        #expect(iterator.next() == nil)
    }

    /// Anthropic reports cache counts outside inputTokens; all three coexist.
    @Test func cachedFixtureSurfacesCacheTokensInUsage() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-cached"))
        let provider = makeProvider(http: http)
        let events = try await collect(provider.stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model,
            tools: [],
            temperature: 0.5
        ))

        #expect(events.last == .messageComplete(usage: TokenUsage(
            inputTokens: 12,
            outputTokens: 3,
            cacheReadInputTokens: 200,
            cacheCreationInputTokens: 100
        )))
    }

    /// Cache usage is first-non-nil-wins, even when later deltas disagree.
    @Test func messageDeltaCacheTokensDoNotClobberMessageStartCounts() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-cached-latch"))
        let provider = makeProvider(http: http)
        let events = try await collect(provider.stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model,
            tools: [],
            temperature: 0.5
        ))

        #expect(events.last == .messageComplete(usage: TokenUsage(
            inputTokens: 12,
            outputTokens: 3,
            cacheReadInputTokens: 200,
            cacheCreationInputTokens: 100
        )))
    }

    @Test func plainTextFixtureIsChunkingInvariant() async throws {
        let whole = try await collect(makeProvider(http: FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: model, tools: [], temperature: 0.5
        ))
        let chunked = try await collect(makeProvider(http: FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"), chunkCount: 7)).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: model, tools: [], temperature: 0.5
        ))
        #expect(whole == chunked)
    }

    @Test func thinkingFixtureProducesThinkingThenTextThenUsage() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-thinking"))
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
            "thinkingSignature",
            "messageComplete",
        ])
        #expect(events.contains(.thinkingDelta(index: 0, text: "Let me think")))
        #expect(events.contains(.thinkingSignature(index: 0, signature: "abc123")))
        #expect(events.contains(.textDelta(index: 1, text: "42")))
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 20, outputTokens: 10)))
    }

    @Test func redactedThinkingSuppressesTheSignature() async throws {
        // Redacted payloads cannot round-trip through persistence. Withholding a signature
        // makes the continuation disable thinking instead of sending a rejected partial replay.
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-thinking-redacted"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model, tools: [], temperature: 0.0
        ))

        #expect(!events.map(Self.kind).contains("thinkingSignature"))
        #expect(events.contains(.thinkingDelta(index: 0, text: "partially visible")))
    }

    @Test func signedToolLoopHistoryReplaysThinkingBlockFirstAndKeepsThinkingEnabled() async throws {
        // A tool continuation must lead with its original signed thinking block, verbatim.
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))
        let history: [LLMMessage] = [
            LLMMessage(role: .user, text: "weather?"),
            LLMMessage(role: .assistant, content: [
                .thinking(content: "I should check the weather tool.", signature: "sig-1"),
                .text("Let me check."),
                .toolUse(id: "toolu_x", name: "get_weather", input: .object(["city": .string("Paris")]), signature: nil),
            ]),
            LLMMessage(role: .tool, content: [
                .toolResult(toolUseID: "toolu_x", content: "18C clear", isError: false),
            ]),
        ]
        _ = try await collect(makeProvider(http: http).stream(
            messages: history, model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        #expect(body["thinking"] != nil)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let assistantContent = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(assistantContent[0]["type"] as? String == "thinking")
        #expect(assistantContent[0]["thinking"] as? String == "I should check the weather tool.")
        #expect(assistantContent[0]["signature"] as? String == "sig-1")
        #expect(assistantContent[1]["type"] as? String == "text")
        #expect(assistantContent[2]["type"] as? String == "tool_use")
    }

    @Test func unsignedToolLoopHistoryOmitsThinkingParameter() async throws {
        // Legacy, redacted, and foreign traces lack replayable signatures. Disable thinking
        // and omit unsigned blocks to avoid a rejected tool continuation.
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))
        let history: [LLMMessage] = [
            LLMMessage(role: .user, text: "weather?"),
            LLMMessage(role: .assistant, content: [
                .thinking(content: "unsigned trace", signature: nil),
                .text("Let me check."),
                .toolUse(id: "toolu_x", name: "get_weather", input: .object(["city": .string("Paris")]), signature: nil),
            ]),
            LLMMessage(role: .tool, content: [
                .toolResult(toolUseID: "toolu_x", content: "18C clear", isError: false),
            ]),
        ]
        _ = try await collect(makeProvider(http: http).stream(
            messages: history, model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        #expect(body["thinking"] == nil)
        #expect(body["temperature"] != nil)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let assistantContent = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(assistantContent.allSatisfy { ($0["type"] as? String) != "thinking" })
    }

    @Test func toolFreeThinkingHistoryKeepsThinkingEnabled() async throws {
        // Unsigned history only disables thinking for tool continuations.
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))
        let history: [LLMMessage] = [
            LLMMessage(role: .user, text: "hello"),
            LLMMessage(role: .assistant, content: [
                .thinking(content: "unsigned trace", signature: nil),
                .text("hi there"),
            ]),
            LLMMessage(role: .user, text: "and again"),
        ]
        _ = try await collect(makeProvider(http: http).stream(
            messages: history, model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        #expect(body["thinking"] != nil)
    }

    @Test func searchFixtureEmitsSearchStartedThenCitationsWithEncryptedEcho() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-search"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "mars news?")],
            model: model, tools: [.nativeSearchSentinel], temperature: 0.7
        ))

        #expect(events.contains(.searchStarted(query: "mars rover news")))
        let searchIndex = events.firstIndex(of: .searchStarted(query: "mars rover news"))
        let firstTextIndex = events.firstIndex { if case .textDelta = $0 { return true } else { return false } }
        #expect(searchIndex != nil && firstTextIndex != nil && searchIndex! < firstTextIndex!)

        // Server-side search blocks consume no normalized content index.
        #expect(events.contains(.textDelta(index: 0, text: "The rover found ice.")))

        let citations = events.flatMap { event -> [SourceCitation] in
            if case .citations(let c) = event { return c } else { return [] }
        }
        #expect(citations.count == 1)
        let citation = try #require(citations.first)
        #expect(citation.url == URL(string: "https://www.nasa.gov/mars")!)
        #expect(citation.title == "NASA Mars")
        #expect(citation.snippet == "found ice")
        // Encrypted content comes from the result; the encrypted index comes from its citation.
        #expect(citation.providerEcho?.kind == AnthropicWebSearch.echoKind)
        #expect(citation.providerEcho?.encryptedContent == "ENC_NASA")
        #expect(citation.providerEcho?.encryptedIndex == "IDX_1")
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 30, outputTokens: 25)))
    }

    @Test func toolCallFixtureAccumulatesArgumentsAndEmitsToolUse() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-toolcall"))
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
        #expect(toolUses.first?.id == "toolu_1")
        #expect(toolUses.first?.name == "get_weather")
        #expect(toolUses.first?.input == .object(["city": .string("Paris")]))
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 15, outputTokens: 8)))
    }

    // MARK: - Error ordering (messageStart-first contract)

    @Test func sseErrorBeforeAnyContentStillEmitsMessageStartFirst() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-error-only"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: model, tools: [], temperature: 0.5
        ))
        #expect(events.map(Self.kind) == ["messageStart", "error", "messageComplete"])
        let errors = events.compactMap { event -> LLMError? in
            if case .error(let e) = event { return e } else { return nil }
        }
        #expect(errors == [.providerError(code: "overloaded_error", message: "Overloaded")])
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    @Test func sseErrorAfterAnOpenTextBlockClosesItBeforeTheError() async throws {
        // Close the open block before the error; closeOut() must not emit a late stop.
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-error-after-text"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "q")], model: model, tools: [], temperature: 0.5
        ))
        #expect(events.suffix(4).map(Self.kind) == ["textDelta", "contentBlockStop", "error", "messageComplete"])
        let errors = events.compactMap { event -> LLMError? in
            if case .error(let e) = event { return e } else { return nil }
        }
        #expect(errors == [.providerError(code: "api_error", message: "boom")])
    }

    @Test func transportErrorAfterAnSSEErrorDoesNotDoubleReport() async throws {
        // ChatSession keeps the last error. A later transport failure must not overwrite
        // the more specific SSE error.
        let http = FakeHTTPClient(
            chunks: [Data(FixtureLoader.load("anthropic-error-only").utf8)],
            error: HTTPError.badStatus(500, body: "")
        )
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "q")], model: model, tools: [], temperature: 0.5
        ))
        let errors = events.compactMap { event -> LLMError? in
            if case .error(let e) = event { return e } else { return nil }
        }
        #expect(errors == [.providerError(code: "overloaded_error", message: "Overloaded")])
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    @Test func transportErrorWithPartialToolCallDoesNotEmitASpuriousDecodingError() async throws {
        // Balance the partial tool block without emitting a call or a decoding error;
        // the transport failure must remain the reported error.
        let http = FakeHTTPClient(
            chunks: [Data(FixtureLoader.load("anthropic-partial-toolcall").utf8)],
            error: HTTPError.badStatus(503, body: "")
        )
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "q")], model: model, tools: [], temperature: 0.5
        ))
        #expect(events.map(Self.kind) == [
            "messageStart", "contentBlockStart(toolUse)", "contentBlockStop", "error", "messageComplete",
        ])
        let errors = events.compactMap { event -> LLMError? in
            if case .error(let e) = event { return e } else { return nil }
        }
        #expect(errors == [.providerError(code: "503", message: "HTTP 503")])
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 7, outputTokens: 0)))
    }

    @Test func unsupportedModelYieldsErrorBeforeCompletion() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))
        let unknown = LLMModel(id: "claude-not-configured", displayName: "Nope", maxContextTokens: 200_000)
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: unknown, tools: [], temperature: 0.5
        ))
        #expect(events.map(Self.kind) == ["messageStart", "error", "messageComplete"])
        let errors = events.compactMap { event -> LLMError? in
            if case .error(let e) = event { return e } else { return nil }
        }
        #expect(errors == [.unsupportedModel("claude-not-configured")])
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

    @Test func requestTargetsMessagesEndpointWithAnthropicHeaders() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))
        _ = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: model, tools: [], temperature: 0.5
        ))
        let request = try #require(http.observed.all.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    }

    @Test func cleartextEndpointOmitsTheKey() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))
        _ = try await collect(makeProvider(http: http, baseURL: URL(string: "http://insecure.example.com/v1")!).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: model, tools: [], temperature: 0.5
        ))
        let request = try #require(http.observed.all.first)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
    }

    @Test func maxTokensIsDerivedAndThinkingOmitsTemperature() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))
        _ = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        #expect(body["max_tokens"] as? Int == 4096)
        // Thinking rejects temperatures other than 1, so omit the parameter.
        let thinking = try #require(body["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "enabled")
        #expect(thinking["budget_tokens"] as? Int == 2048)
        #expect(body["temperature"] == nil)
    }

    @Test func nonThinkingModelSendsClampedTemperatureAndNoThinking() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))
        _ = try await collect(makeProvider(http: http, model: nonThinkingModel).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: nonThinkingModel, tools: [], temperature: 3.0
        ))
        let body = try Self.decodeBody(http)
        #expect(body["thinking"] == nil)
        #expect(body["temperature"] as? Double == 1.0)
    }

    @Test func systemMessageBecomesSystemFieldAndUserBecomesMessage() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))
        _ = try await collect(makeProvider(http: http).stream(
            messages: [
                LLMMessage(role: .system, text: "You are terse."),
                LLMMessage(role: .user, text: "hi"),
            ],
            model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let system = try Self.systemBlocks(body)
        #expect(system.count == 1)
        #expect(system[0]["type"] as? String == "text")
        #expect(system[0]["text"] as? String == "You are terse.")
        #expect(system[0]["cache_control"] == nil)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(content[0]["type"] as? String == "text")
        #expect(content[0]["text"] as? String == "hi")
    }

    // MARK: - Prompt-cache breakpoints

    @Test func stablePrefixSystemBlockGetsCacheControlAndVolatileDoesNot() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))
        _ = try await collect(makeProvider(http: http).stream(
            messages: [
                LLMMessage(role: .system, text: "Stable briefing.", cacheHint: .stablePrefix),
                LLMMessage(role: .system, text: "Volatile memories.", cacheHint: .volatile),
                LLMMessage(role: .user, text: "hi"),
            ],
            model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let system = try Self.systemBlocks(body)
        #expect(system.count == 2)
        #expect(system[0]["text"] as? String == "Stable briefing.")
        let marker = try #require(system[0]["cache_control"] as? [String: Any])
        #expect(marker["type"] as? String == "ephemeral")
        #expect(system[1]["text"] as? String == "Volatile memories.")
        #expect(system[1]["cache_control"] == nil)
    }

    @Test func onlyStableSystemProducesASingleMarkedBlock() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))
        _ = try await collect(makeProvider(http: http).stream(
            messages: [
                LLMMessage(role: .system, text: "Stable only.", cacheHint: .stablePrefix),
                LLMMessage(role: .user, text: "hi"),
            ],
            model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let system = try Self.systemBlocks(body)
        #expect(system.count == 1)
        #expect(system[0]["text"] as? String == "Stable only.")
        #expect((system[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    }

    /// Demote misplaced stable hints to keep the cached prefix contiguous.
    @Test func stableSystemAfterVolatileDemotesToVolatileBucket() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))
        _ = try await collect(makeProvider(http: http).stream(
            messages: [
                LLMMessage(role: .system, text: "Stable A.", cacheHint: .stablePrefix),
                LLMMessage(role: .system, text: "Volatile B.", cacheHint: .volatile),
                LLMMessage(role: .system, text: "Misplaced stable C.", cacheHint: .stablePrefix),
                LLMMessage(role: .user, text: "hi"),
            ],
            model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let system = try Self.systemBlocks(body)
        #expect(system.count == 2)
        #expect(system[0]["text"] as? String == "Stable A.")
        #expect((system[0]["cache_control"] as? [String: Any]) != nil)
        #expect(system[1]["text"] as? String == "Volatile B.\n\nMisplaced stable C.")
        #expect(system[1]["cache_control"] == nil)
    }

    @Test func lastContentBlockOfLastMessageCarriesCacheControl() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))
        _ = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let lastContent = try #require(messages.last?["content"] as? [[String: Any]])
        let lastBlock = try #require(lastContent.last)
        #expect(lastBlock["type"] as? String == "text")
        #expect(lastBlock["text"] as? String == "hi")
        #expect((lastBlock["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    }

    @Test func movingBreakpointWrapsAToolResultFinalTurn() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))
        let history: [LLMMessage] = [
            LLMMessage(role: .user, text: "weather?"),
            LLMMessage(role: .assistant, content: [
                .toolUse(id: "tu1", name: "get_weather", input: .object(["city": .string("NYC")]), signature: nil),
            ]),
            LLMMessage(role: .tool, content: [
                .toolResult(toolUseID: "tu1", content: "Sunny", isError: false),
            ]),
        ]
        _ = try await collect(makeProvider(http: http).stream(
            messages: history, model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let lastContent = try #require(messages.last?["content"] as? [[String: Any]])
        let lastBlock = try #require(lastContent.last)
        #expect(lastBlock["type"] as? String == "tool_result")
        #expect((lastBlock["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    }

    @Test func cachedBlockEncodesInnerBlockPlusMergedCacheControl() throws {
        let data = try JSONEncoder().encode(AnthropicContentBlock.cached(.text("hello")))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "text")
        #expect(json["text"] as? String == "hello")
        #expect((json["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    }

    /// Anthropic uses cache_control; the conversation routing key must not reach the wire.
    @Test func optionsOverloadLeavesTheAnthropicRequestUnchanged() async throws {
        // Compare parsed JSON because keyed-container encoding order is unspecified.
        func body(passingOptions: Bool) async throws -> NSDictionary {
            let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))
            let provider = makeProvider(http: http)
            let messages = [LLMMessage(role: .user, text: "hi")]
            let stream = passingOptions
                ? provider.stream(
                    messages: messages, model: model, tools: [], temperature: 0.5,
                    options: LLMRequestOptions(conversationCacheKey: "conv-leak-canary"))
                : provider.stream(messages: messages, model: model, tools: [], temperature: 0.5)
            _ = try await collect(stream)
            let request = try #require(http.observed.all.first)
            let data = try #require(request.httpBody)
            return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
        }
        let withOptions = try await body(passingOptions: true)
        let withoutOptions = try await body(passingOptions: false)
        #expect(withOptions == withoutOptions)
    }

    @Test func nativeSearchSentinelBecomesWebSearchToolAndIsStrippedFromTools() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))
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
        let names = tools.compactMap { $0["name"] as? String }
        #expect(names.contains("get_weather"))
        #expect(names.contains("web_search"))
        #expect(!names.contains(NativeWebSearch.sentinelToolName))
        let webSearch = try #require(tools.first { $0["name"] as? String == "web_search" })
        #expect(webSearch["type"] as? String == "web_search_20250305")
        #expect(webSearch["max_uses"] as? Int == 5)
        let custom = try #require(tools.first { $0["name"] as? String == "get_weather" })
        #expect(custom["input_schema"] != nil)
    }

    @Test func noToolsOmitsToolsKeyEntirely() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))
        _ = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")], model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        #expect(body["tools"] == nil)
    }

    @Test func toolResultRidesAUserMessageAndMergesWithAdjacentUserText() async throws {
        // Anthropic has no tool role. Results use user blocks and merge with adjacent
        // user messages to preserve role alternation.
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))
        let history: [LLMMessage] = [
            LLMMessage(role: .user, text: "weather?"),
            LLMMessage(role: .assistant, content: [
                .text("Let me check."),
                .toolUse(id: "toolu_x", name: "get_weather", input: .object(["city": .string("Paris")]), signature: nil),
            ]),
            LLMMessage(role: .tool, content: [
                .toolResult(toolUseID: "toolu_x", content: "18C clear", isError: false),
            ]),
            LLMMessage(role: .user, text: "thanks"),
        ]
        _ = try await collect(makeProvider(http: http).stream(
            messages: history, model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])

        let assistantContent = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(assistantContent[0]["type"] as? String == "text")
        #expect(assistantContent[1]["type"] as? String == "tool_use")
        #expect(assistantContent[1]["id"] as? String == "toolu_x")

        let mergedUser = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(mergedUser[0]["type"] as? String == "tool_result")
        #expect(mergedUser[0]["tool_use_id"] as? String == "toolu_x")
        #expect(mergedUser[0]["content"] as? String == "18C clear")
        #expect(mergedUser[1]["type"] as? String == "text")
        #expect(mergedUser[1]["text"] as? String == "thanks")
    }

    @Test func assistantFirstHistoryGetsASyntheticUserOpener() async throws {
        // Old checkpoints may leave an assistant-first window after system rows are
        // hoisted. Repair it to satisfy the API requirement for a leading user message.
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))
        let history: [LLMMessage] = [
            LLMMessage(role: .system, text: "Summary of earlier conversation (compacted): stuff happened."),
            LLMMessage(role: .assistant, content: [
                .text("Checking."),
                .toolUse(id: "toolu_y", name: "get_weather", input: .object(["city": .string("Oslo")]), signature: nil),
            ]),
            LLMMessage(role: .tool, content: [
                .toolResult(toolUseID: "toolu_y", content: "3C snow", isError: false),
            ]),
        ]
        _ = try await collect(makeProvider(http: http).stream(
            messages: history, model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let opener = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(opener[0]["type"] as? String == "text")
        #expect(opener[0]["text"] as? String == "(Conversation resumed after context compaction.)")
        let assistantContent = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(assistantContent.contains { $0["type"] as? String == "tool_use" })
        #expect(try Self.systemText(body).contains("stuff happened"))
    }

    @Test func userFirstHistoryGetsNoSyntheticOpener() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))
        _ = try await collect(makeProvider(http: http).stream(
            messages: [
                LLMMessage(role: .user, text: "hi"),
                LLMMessage(role: .assistant, text: "hello"),
                LLMMessage(role: .user, text: "again"),
            ],
            model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 3)
        let first = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(first[0]["text"] as? String == "hi")
    }

    @Test func searchResultBlockReplaysAsWebSearchToolResultWithEncryptedContent() async throws {
        // Replay the opaque search result before text so its citations remain valid.
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))
        let cited = SourceCitation(
            id: "c1",
            title: "NASA Mars",
            url: URL(string: "https://www.nasa.gov/mars")!,
            snippet: "found ice",
            providerEcho: ProviderEcho(
                kind: AnthropicWebSearch.echoKind,
                encryptedContent: "ENC_NASA",
                encryptedIndex: "IDX_1"
            )
        )
        let history: [LLMMessage] = [
            LLMMessage(role: .user, text: "mars?"),
            LLMMessage(role: .assistant, content: [
                .searchResult([cited]),
                .text("The rover found ice."),
            ]),
            LLMMessage(role: .user, text: "more?"),
        ]
        _ = try await collect(makeProvider(http: http).stream(
            messages: history, model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let assistantContent = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(assistantContent[0]["type"] as? String == "web_search_tool_result")
        #expect(assistantContent[1]["type"] as? String == "text")
        // Stable FNV-1a URL IDs let replayed citations reference their synthetic server tool.
        let toolUseID = try #require(assistantContent[0]["tool_use_id"] as? String)
        #expect(toolUseID.hasPrefix("srvtoolu_"))
        #expect(toolUseID != "srvtoolu_")
        let results = try #require(assistantContent[0]["content"] as? [[String: Any]])
        #expect(results[0]["type"] as? String == "web_search_result")
        #expect(results[0]["url"] as? String == "https://www.nasa.gov/mars")
        #expect(results[0]["encrypted_content"] as? String == "ENC_NASA")
    }

    @Test func searchResultWithoutAnthropicEchoIsNotReplayed() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))
        let foreign = SourceCitation(
            id: "c1", title: "T", url: URL(string: "https://example.com/a")!
        )
        let history: [LLMMessage] = [
            LLMMessage(role: .assistant, content: [
                .searchResult([foreign]),
                .text("answer"),
            ]),
            LLMMessage(role: .user, text: "next"),
        ]
        _ = try await collect(makeProvider(http: http).stream(
            messages: history, model: model, tools: [], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let assistantContent = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(assistantContent.count == 1)
        #expect(assistantContent[0]["type"] as? String == "text")
    }

    // MARK: - Tool wire-name sanitization (dot-namespaced tool IDs)

    // Anthropic tool names reject dots; encode local IDs for the wire.
    @Test func dotNamespacedToolNameIsSanitizedInToolDefinitions() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))
        _ = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model, tools: [.dotNamedTimeTool], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["time_now"])
    }

    @Test func dotNamespacedHistoryToolCallEncodesTheSanitizedWireName() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-plain"))
        let history: [LLMMessage] = [
            LLMMessage(role: .user, text: "time?"),
            LLMMessage(role: .assistant, content: [
                .toolUse(id: "toolu_x", name: "time.now", input: .object([:]), signature: nil),
            ]),
            LLMMessage(role: .tool, content: [
                .toolResult(toolUseID: "toolu_x", content: "12:00", isError: false),
            ]),
        ]
        _ = try await collect(makeProvider(http: http).stream(
            messages: history, model: model, tools: [.dotNamedTimeTool], temperature: 0.5
        ))
        let body = try Self.decodeBody(http)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let assistantContent = try #require(messages[1]["content"] as? [[String: Any]])
        let toolUse = try #require(assistantContent.first { $0["type"] as? String == "tool_use" })
        #expect(toolUse["name"] as? String == "time_now")
    }

    @Test func streamedToolCallNameIsRestoredToTheRegistryName() async throws {
        // Restore the original local ID before ToolRegistry lookup.
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-toolcall-dotname"))
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

    private static func systemBlocks(_ body: [String: Any]) throws -> [[String: Any]] {
        try #require(body["system"] as? [[String: Any]])
    }

    private static func systemText(_ body: [String: Any]) throws -> String {
        try systemBlocks(body).compactMap { $0["text"] as? String }.joined(separator: "\n\n")
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
