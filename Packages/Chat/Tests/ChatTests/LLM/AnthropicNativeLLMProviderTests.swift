import Core
import Foundation
import Testing
@testable import Chat

/// End-to-end tests for `AnthropicNativeLLMProvider`. Exercises the request
/// shape (URL, `x-api-key` + `anthropic-version` headers, `max_tokens`
/// derivation, thinking/temperature interaction, system/tool/search-result
/// translation) and the full streaming pipeline by replaying recorded Messages
/// SSE (Server-Sent Events) fixtures through a fake HTTP client. No real
/// network — ever (per Chat `AGENTS.md`).
///
/// **Stream contract**: every test asserts the stream terminates with
/// `.messageComplete`; failures surface as `.error` events, never throws.
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

    /// Chunked delivery must produce the identical event stream — proves the SSE
    /// parser's partial-frame handling holds for the Messages framing.
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

        // The `signature_delta` is dropped; thinking and text occupy distinct
        // normalized block indices (0 then 1).
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
        #expect(events.contains(.thinkingDelta(index: 0, text: "Let me think")))
        #expect(events.contains(.textDelta(index: 1, text: "42")))
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 20, outputTokens: 10)))
    }

    @Test func searchFixtureEmitsSearchStartedThenCitationsWithEncryptedEcho() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("anthropic-search"))
        let events = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "mars news?")],
            model: model, tools: [.nativeSearchSentinel], temperature: 0.7
        ))

        // searchStarted carries the server_tool_use query and precedes the text.
        #expect(events.contains(.searchStarted(query: "mars rover news")))
        let searchIndex = events.firstIndex(of: .searchStarted(query: "mars rover news"))
        let firstTextIndex = events.firstIndex { if case .textDelta = $0 { return true } else { return false } }
        #expect(searchIndex != nil && firstTextIndex != nil && searchIndex! < firstTextIndex!)

        // The server_tool_use / web_search_tool_result blocks consume no
        // normalized index, so the visible text block is index 0.
        #expect(events.contains(.textDelta(index: 0, text: "The rover found ice.")))

        let citations = events.flatMap { event -> [SourceCitation] in
            if case .citations(let c) = event { return c } else { return [] }
        }
        #expect(citations.count == 1)
        let citation = try #require(citations.first)
        #expect(citation.url == URL(string: "https://www.nasa.gov/mars")!)
        #expect(citation.title == "NASA Mars")
        #expect(citation.snippet == "found ice")
        // The encrypted echo is stashed from the result block by URL and the
        // index from the citation — both must round-trip verbatim.
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

        // The tool block is opened on content_block_start and the `.toolUse`
        // payload emitted on content_block_stop (args fully accumulated).
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
        // The SSE `error` path must close an open block before the error so the
        // later `closeOut()` doesn't emit `.contentBlockStop` after `.error`.
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
        // An SSE `error` fires, then the transport also drops. The catch must
        // not yield a second, less-specific error over the already-surfaced
        // provider error (`ChatSession` keeps the last one).
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
        // A `tool_use` whose argument deltas are mid-stream when the transport
        // drops: the open block's start is balanced with a stop, but no
        // `.toolUse` (and no `.decodingFailed`) is emitted — only the transport
        // error, which `ChatSession` keeps.
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
        // A model whose id isn't in `supportedModels` is rejected before any
        // request is issued; the failure still rides the stream contract
        // (messageStart-first, error immediately before the terminal).
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
        // Anthropic authenticates with x-api-key + a version header, NOT bearer.
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
        // min(200_000 / 4, 4096) = 4096.
        #expect(body["max_tokens"] as? Int == 4096)
        // Thinking-capable model: thinking enabled, temperature omitted (the API
        // rejects any value other than 1 with thinking).
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
        // Anthropic accepts [0, 1]; out-of-range clamps rather than rejects.
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
        #expect(body["system"] as? String == "You are terse.")
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(content[0]["type"] as? String == "text")
        #expect(content[0]["text"] as? String == "hi")
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
        // The custom tool serializes with input_schema; the sentinel becomes the
        // versioned web_search server tool and never appears as a custom tool.
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
        // Anthropic has no `tool` role: a Core `.tool` message becomes a
        // `user`-role message with a tool_result block, and an immediately
        // following user message merges into it (strict role alternation).
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
        // user, assistant, then a single merged user (tool_result + "thanks").
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

    @Test func searchResultBlockReplaysAsWebSearchToolResultWithEncryptedContent() async throws {
        // A prior assistant turn's stored citations (with the Anthropic echo)
        // ride back as a `.searchResult` block, which must serialize into a
        // `web_search_tool_result` content block carrying the verbatim
        // `encrypted_content` before the assistant's text.
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
        // web_search_tool_result precedes the text.
        #expect(assistantContent[0]["type"] as? String == "web_search_tool_result")
        #expect(assistantContent[1]["type"] as? String == "text")
        // The synthetic tool_use_id is deterministic (FNV-1a over the result
        // URLs) so the payload is reproducible — see the adapter's stableHash.
        let toolUseID = try #require(assistantContent[0]["tool_use_id"] as? String)
        #expect(toolUseID.hasPrefix("srvtoolu_"))
        #expect(toolUseID != "srvtoolu_")
        let results = try #require(assistantContent[0]["content"] as? [[String: Any]])
        #expect(results[0]["type"] as? String == "web_search_result")
        #expect(results[0]["url"] as? String == "https://www.nasa.gov/mars")
        #expect(results[0]["encrypted_content"] as? String == "ENC_NASA")
    }

    @Test func searchResultWithoutAnthropicEchoIsNotReplayed() async throws {
        // Citations from another provider (no Anthropic echo) replayed into an
        // Anthropic turn produce no web_search_tool_result — only the text.
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

    /// Regression: Anthropic rejects dot-namespaced names
    /// (`tools.0.custom.name: String should match pattern
    /// '^[a-zA-Z0-9_-]{1,128}$'`), which 400'd every turn that advertised
    /// Super's `time.now`-style tools.
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
        // The replayed assistant `tool_use` block must carry the same
        // sanitized wire name as the tool definition.
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
        // The model calls back with the wire name; the emitted `.toolUse`
        // must carry the original dot name for the `ToolRegistry` lookup.
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
