import Core
import Foundation
import Testing
@testable import Chat

/// End-to-end tests for `OpenAICompatibleLLMProvider`. Exercises the
/// request shape (URL, headers, body) and the full streaming pipeline by
/// replaying recorded SSE (Server-Sent Events) fixtures through a fake
/// HTTP (HyperText Transfer Protocol) client. No real network — ever.
///
/// **Stream contract**: every test asserts the stream finishes cleanly and
/// terminates with `.messageComplete`. Failures are surfaced as `.error`
/// events immediately before the terminal `.messageComplete`, never as
/// thrown errors.
@Suite("OpenAICompatibleLLMProvider")
struct OpenAICompatibleLLMProviderTests {
    private let baseURL = URL(string: "https://api.example.test/v1")!
    private let model = LLMModel(
        id: "gpt-4o-mini",
        displayName: "GPT-4o mini",
        supportsThinking: false,
        supportsTools: true,
        maxContextTokens: 16_000
    )

    private func makeProvider(
        http: HTTPClient,
        baseURL: URL? = nil,
        apiKey: String? = "sk-test"
    ) -> OpenAICompatibleLLMProvider {
        OpenAICompatibleLLMProvider(
            id: "cfg-1",
            displayName: "Test",
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

    /// The configuration's `searchBackend` must reach the vended `LLMModel` —
    /// the turn loop reads `model.searchBackend` to drive the client-mock
    /// ("debug") search path on an otherwise-ordinary OpenAI-compat model.
    /// Regression: the convenience init previously dropped it (left nil).
    @Test func convenienceInitStampsSearchBackendOntoVendedModel() async throws {
        let configuration = ModelConfiguration(
            id: "cfg-1",
            kind: .openAICompatible,
            name: "Mock-backed model",
            baseURL: baseURL,
            apiKeyRef: nil,
            modelID: "gpt-4o-mini",
            searchBackend: "debug"
        )
        let provider = OpenAICompatibleLLMProvider(
            configuration: configuration,
            apiKey: "sk-test",
            http: FakeHTTPClient(chunks: [])
        )
        #expect(provider.supportedModels.first?.searchBackend == "debug")
    }

    @Test func convenienceInitLeavesSearchBackendNilWhenUnset() async throws {
        let configuration = ModelConfiguration(
            id: "cfg-2",
            kind: .openAICompatible,
            name: "Plain model",
            baseURL: baseURL,
            apiKeyRef: nil,
            modelID: "gpt-4o-mini"
        )
        let provider = OpenAICompatibleLLMProvider(
            configuration: configuration,
            apiKey: nil,
            http: FakeHTTPClient(chunks: [])
        )
        #expect(provider.supportedModels.first?.searchBackend == nil)
    }

    private func errorEvents(_ events: [LLMStreamEvent]) -> [LLMError] {
        events.compactMap { event in
            if case .error(let error) = event { return error }
            return nil
        }
    }

    @Test func plainTextFixtureProducesOrderedTextEventsAndUsage() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-plain"))
        let provider = makeProvider(http: http)
        let events = try await collect(provider.stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model,
            tools: [],
            temperature: 0.5
        ))

        var iterator = events.makeIterator()
        #expect(iterator.next() == .messageStart(id: "chatcmpl-plain", model: "gpt-4o-mini"))
        #expect(iterator.next() == .contentBlockStart(index: 0, type: .text))
        #expect(iterator.next() == .textDelta(index: 0, text: "Hello"))
        #expect(iterator.next() == .textDelta(index: 0, text: " there"))
        #expect(iterator.next() == .textDelta(index: 0, text: "!"))
        #expect(iterator.next() == .contentBlockStop(index: 0))
        #expect(iterator.next() == .messageComplete(usage: TokenUsage(inputTokens: 11, outputTokens: 3)))
        #expect(iterator.next() == nil)
    }

    /// `prompt_tokens_details.cached_tokens` surfaces as `cacheReadInputTokens`.
    /// OpenAI (and xAI, identical shape) report cached tokens as a subset of
    /// `promptTokens`, and have no write count — `cacheCreationInputTokens` nil.
    @Test func cachedFixtureSurfacesCachedTokensInUsage() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-cached"))
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
            cacheReadInputTokens: 896,
            cacheCreationInputTokens: nil
        )))
    }

    @Test func reasoningFixtureProducesThinkingThenTextThenUsage() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-reasoning"))
        let provider = makeProvider(http: http)
        let events = try await collect(provider.stream(
            messages: [LLMMessage(role: .user, text: "what is 6*7?")],
            model: model,
            tools: [],
            temperature: 0.0
        ))

        let kinds = events.map(eventKind(_:))
        #expect(kinds == [
            "messageStart",
            "contentBlockStart(thinking)",
            "thinkingDelta",
            "thinkingDelta",
            "contentBlockStop(0)",
            "contentBlockStart(text)",
            "textDelta",
            "contentBlockStop(1)",
            "messageComplete",
        ])

        let thinking = events.compactMap { event -> String? in
            if case .thinkingDelta(_, let text) = event { return text }
            return nil
        }
        #expect(thinking == ["Let me think", " carefully."])
    }

    @Test func toolCallFixtureProducesAccumulatedToolUseAndUsage() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-toolcall"))
        let provider = makeProvider(http: http)
        let events = try await collect(provider.stream(
            messages: [LLMMessage(role: .user, text: "what time is it?")],
            model: model,
            tools: [],
            temperature: 0.5
        ))

        let toolUses = events.compactMap { event -> (String, String, JSONValue)? in
            if case .toolUse(_, let id, let name, let input, _) = event { return (id, name, input) }
            return nil
        }
        #expect(toolUses.count == 1)
        #expect(toolUses.first?.0 == "call_abc")
        #expect(toolUses.first?.1 == "get_time")
        #expect(toolUses.first?.2 == .object(["timezone": .string("UTC")]))

        if case .messageComplete(let usage) = events.last {
            #expect(usage == TokenUsage(inputTokens: 15, outputTokens: 8))
        } else {
            Issue.record("expected trailing messageComplete")
        }
    }

    @Test func interleavedReasoningAndToolFixtureEmitsBothInOrder() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-reasoning-and-tools"))
        let provider = makeProvider(http: http)
        let events = try await collect(provider.stream(
            messages: [LLMMessage(role: .user, text: "what time is it?")],
            model: model,
            tools: [],
            temperature: 0.0
        ))

        let kinds = events.map(eventKind(_:))
        #expect(kinds == [
            "messageStart",
            "contentBlockStart(thinking)",
            "thinkingDelta",
            "thinkingDelta",
            "contentBlockStop(0)",
            "contentBlockStart(toolUse)",
            "toolUse",
            "contentBlockStop(1)",
            "messageComplete",
        ])
    }

    @Test func toolCallFragmentAndFinishReasonInSameChunkFlushes() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-toolcall-finish-same-chunk"))
        let provider = makeProvider(http: http)
        let events = try await collect(provider.stream(
            messages: [LLMMessage(role: .user, text: "what time is it?")],
            model: model,
            tools: [],
            temperature: 0.0
        ))

        let toolUses = events.compactMap { event -> (String, JSONValue)? in
            if case .toolUse(_, let id, _, let input, _) = event { return (id, input) }
            return nil
        }
        #expect(toolUses.count == 1)
        #expect(toolUses.first?.0 == "call_same")
        #expect(toolUses.first?.1 == .object(["timezone": .string("UTC")]))
    }

    @Test func partialChunkBoundariesStillProduceCompleteEvents() async throws {
        let http = FakeHTTPClient.fromFixture(
            FixtureLoader.load("openai-plain"),
            chunkCount: 17
        )
        let provider = makeProvider(http: http)
        let events = try await collect(provider.stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model,
            tools: [],
            temperature: 0.5
        ))

        let textDeltas = events.compactMap { event -> String? in
            if case .textDelta(_, let text) = event { return text }
            return nil
        }
        #expect(textDeltas.joined() == "Hello there!")
    }

    @Test func unsupportedModelEmitsErrorEventAndDoesNotIssueHTTPRequest() async throws {
        let http = FakeHTTPClient(chunks: [])
        let provider = makeProvider(http: http)
        let other = LLMModel(id: "not-a-real-model", displayName: "Other")
        let events = try await collect(provider.stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: other,
            tools: [],
            temperature: 0.5
        ))

        #expect(errorEvents(events) == [.unsupportedModel("not-a-real-model")])
        if case .messageComplete = events.last { } else {
            Issue.record("expected trailing messageComplete")
        }
        #expect(http.observed.all.isEmpty)
    }

    @Test func httpStatus401EmitsUnauthorizedErrorThenMessageComplete() async throws {
        let events = try await collectErrorRun(error: HTTPError.badStatus(401, body: ""))
        #expect(errorEvents(events) == [.unauthorized])
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    @Test func httpStatus429EmitsRateLimitedErrorThenMessageComplete() async throws {
        let events = try await collectErrorRun(error: HTTPError.badStatus(429, body: ""))
        #expect(errorEvents(events) == [.rateLimited])
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    @Test func httpStatus5xxEmitsProviderErrorThenMessageComplete() async throws {
        let events = try await collectErrorRun(error: HTTPError.badStatus(503, body: ""))
        #expect(errorEvents(events) == [.providerError(code: "503", message: "HTTP 503")])
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    @Test func httpErrorBodyIsFoldedIntoProviderErrorMessage() async throws {
        // The captured response body (e.g. Gemini's schema-validation
        // explanation) must reach the surfaced error so a 400 is diagnosable.
        let body = "entries.items: missing field"
        let events = try await collectErrorRun(error: HTTPError.badStatus(400, body: body))
        #expect(errorEvents(events) == [.providerError(code: "400", message: "HTTP 400: \(body)")])
    }

    @Test func malformedSSEDataLineEmitsDecodingFailedErrorThenMessageComplete() async throws {
        let bytes = Data("data: not-json\n\n".utf8)
        let http = FakeHTTPClient(chunks: [bytes])
        let provider = makeProvider(http: http)
        let events = try await collect(provider.stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model,
            tools: [],
            temperature: 0.5
        ))
        let errors = errorEvents(events)
        #expect(errors.count == 1)
        if case .decodingFailed = errors.first { } else {
            Issue.record("expected .decodingFailed, got \(String(describing: errors.first))")
        }
        if case .messageComplete = events.last { } else {
            Issue.record("expected trailing messageComplete")
        }
    }

    @Test func cancellationErrorFromTransportMapsToCancelled() async throws {
        let events = try await collectErrorRun(error: CancellationError())
        #expect(errorEvents(events) == [.cancelled])
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    @Test func urlErrorCancelledFromTransportMapsToCancelled() async throws {
        let events = try await collectErrorRun(error: URLError(.cancelled))
        #expect(errorEvents(events) == [.cancelled])
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    @Test func requestTargetsChatCompletionsPath() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-plain"))
        let provider = makeProvider(http: http)
        _ = try await collect(provider.stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model,
            tools: [],
            temperature: 0.5
        ))

        let request = try #require(http.observed.all.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.example.test/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    }

    @Test func baseURLWithTrailingSlashStillProducesCanonicalURL() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-plain"))
        let provider = makeProvider(
            http: http,
            baseURL: URL(string: "https://api.example.test/v1/")!
        )
        _ = try await collect(provider.stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model,
            tools: [],
            temperature: 0.5
        ))
        let request = try #require(http.observed.all.first)
        #expect(request.url?.absoluteString == "https://api.example.test/v1/chat/completions")
    }

    @Test func baseURLAlreadyEndingInChatCompletionsIsNotDoublePathed() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-plain"))
        let provider = makeProvider(
            http: http,
            baseURL: URL(string: "https://api.example.test/v1/chat/completions")!
        )
        _ = try await collect(provider.stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model,
            tools: [],
            temperature: 0.5
        ))
        let request = try #require(http.observed.all.first)
        #expect(request.url?.absoluteString == "https://api.example.test/v1/chat/completions")
    }

    @Test func nilApiKeyOmitsAuthorizationHeader() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-plain"))
        let provider = makeProvider(http: http, apiKey: nil)
        _ = try await collect(provider.stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model,
            tools: [],
            temperature: 0.5
        ))
        let request = try #require(http.observed.all.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func bearerSuppressedForCleartextNonLoopbackHost() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-plain"))
        let provider = makeProvider(
            http: http,
            baseURL: URL(string: "http://example.com/v1")!,
            apiKey: "sk-leak-canary"
        )
        _ = try await collect(provider.stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model,
            tools: [],
            temperature: 0.5
        ))
        let request = try #require(http.observed.all.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func bearerAllowedForHttpLoopback() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-plain"))
        let provider = makeProvider(
            http: http,
            baseURL: URL(string: "http://localhost:11434/v1")!,
            apiKey: "local-key"
        )
        _ = try await collect(provider.stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model,
            tools: [],
            temperature: 0.5
        ))
        let request = try #require(http.observed.all.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-key")
    }

    @Test func temperatureClampedToProviderRange() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-plain"))
        let provider = makeProvider(http: http)
        _ = try await collect(provider.stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model,
            tools: [],
            temperature: 9.9   // Out of OpenAI's [0.0, 2.0] range.
        ))
        let request = try #require(http.observed.all.first)
        let body = try #require(request.httpBody)
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(decoded["temperature"] as? Double == 2.0)
    }

    @Test func requestBodyEncodesMessagesToolsAndStreamFlag() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-plain"))
        let provider = makeProvider(http: http)
        let tool = LLMTool(
            id: "time-now",
            name: "get_time",
            description: "Returns the current time.",
            category: .query,
            parameters: [
                LLMToolParameter(
                    name: "timezone",
                    type: .string,
                    description: "IANA tz id",
                    isRequired: true
                ),
            ],
            appletId: "chat"
        )
        _ = try await collect(provider.stream(
            messages: [
                LLMMessage(role: .system, text: "You are helpful."),
                LLMMessage(role: .user, text: "what time is it?"),
            ],
            model: model,
            tools: [tool],
            temperature: 0.7
        ))

        let request = try #require(http.observed.all.first)
        let body = try #require(request.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let unwrapped = try #require(decoded)
        #expect(unwrapped["model"] as? String == "gpt-4o-mini")
        #expect(unwrapped["stream"] as? Bool == true)
        #expect(unwrapped["temperature"] as? Double == 0.7)
        #expect((unwrapped["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)

        let messages = try #require(unwrapped["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "You are helpful.")
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "what time is it?")

        let tools = try #require(unwrapped["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        let function = try #require(tools[0]["function"] as? [String: Any])
        #expect(function["name"] as? String == "get_time")
        let parameters = try #require(function["parameters"] as? [String: Any])
        #expect(parameters["type"] as? String == "object")
        let required = try #require(parameters["required"] as? [String])
        #expect(required == ["timezone"])
    }

    @Test func toolWithNoRequiredParametersOmitsRequiredKey() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-plain"))
        let provider = makeProvider(http: http)
        let tool = LLMTool(
            id: "time-now",
            name: "get_time",
            description: "Returns the current time.",
            category: .query,
            parameters: [
                LLMToolParameter(
                    name: "timezone",
                    type: .string,
                    description: "IANA tz id",
                    isRequired: false   // none required
                ),
            ],
            appletId: "chat"
        )
        _ = try await collect(provider.stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model,
            tools: [tool],
            temperature: 0.5
        ))
        let request = try #require(http.observed.all.first)
        let body = try #require(request.httpBody)
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tools = try #require(decoded["tools"] as? [[String: Any]])
        let parameters = try #require((tools[0]["function"] as? [String: Any])?["parameters"] as? [String: Any])
        // `required` must be absent (not `[]`) — some local OpenAI shims
        // reject empty arrays.
        #expect(parameters["required"] == nil)
    }

    @Test func toolResultMessagesEncodeAsToolRoleWithToolCallId() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-plain"))
        let provider = makeProvider(http: http)
        let messages: [LLMMessage] = [
            LLMMessage(role: .user, text: "what time is it?"),
            LLMMessage(role: .assistant, content: [
                .toolUse(
                    id: "call_abc",
                    name: "get_time",
                    input: .object(["timezone": .string("UTC")])
                , signature: nil),
            ]),
            LLMMessage(role: .tool, content: [
                .toolResult(toolUseID: "call_abc", content: "12:00 UTC", isError: false)
            ]),
        ]
        _ = try await collect(provider.stream(
            messages: messages,
            model: model,
            tools: [],
            temperature: 0.0
        ))

        let request = try #require(http.observed.all.first)
        let body = try #require(request.httpBody)
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let outgoing = try #require(decoded["messages"] as? [[String: Any]])
        #expect(outgoing.count == 3)

        let assistant = outgoing[1]
        #expect(assistant["role"] as? String == "assistant")
        let toolCalls = try #require(assistant["tool_calls"] as? [[String: Any]])
        #expect(toolCalls.count == 1)
        #expect(toolCalls[0]["id"] as? String == "call_abc")
        let function = try #require(toolCalls[0]["function"] as? [String: Any])
        #expect(function["name"] as? String == "get_time")
        let argsString = try #require(function["arguments"] as? String)
        let parsedArgs = try JSONSerialization.jsonObject(with: Data(argsString.utf8)) as? [String: Any]
        #expect(parsedArgs?["timezone"] as? String == "UTC")

        let toolResult = outgoing[2]
        #expect(toolResult["role"] as? String == "tool")
        #expect(toolResult["tool_call_id"] as? String == "call_abc")
        #expect(toolResult["content"] as? String == "12:00 UTC")
    }

    @Test func captureThoughtSignatureFromToolCallExtraContent() async throws {
        // Gemini over the OpenAI-compat shim carries the thought signature in
        // `extra_content.google.thought_signature` on the streamed tool call.
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-toolcall-signature"))
        let provider = makeProvider(http: http)
        let events = try await collect(provider.stream(
            messages: [LLMMessage(role: .user, text: "what time is it?")],
            model: model, tools: [], temperature: 0.0
        ))
        let signature = events.compactMap { event -> String? in
            if case .toolUse(_, _, _, _, let signature) = event { return signature }
            return nil
        }.first
        #expect(signature == "SIG-compat-1")
    }

    @Test func replayedToolCallEncodesThoughtSignatureInExtraContent() async throws {
        // On the follow-up turn the signature must ride the outgoing tool call's
        // `extra_content.google.thought_signature`, or the shim 400s.
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-plain"))
        let provider = makeProvider(http: http)
        let messages: [LLMMessage] = [
            LLMMessage(role: .user, text: "what time is it?"),
            LLMMessage(role: .assistant, content: [
                .toolUse(id: "call_abc", name: "get_time",
                         input: .object(["timezone": .string("UTC")]), signature: "SIG-xyz"),
            ]),
            LLMMessage(role: .tool, content: [
                .toolResult(toolUseID: "call_abc", content: "12:00 UTC", isError: false),
            ]),
        ]
        _ = try await collect(provider.stream(messages: messages, model: model, tools: [], temperature: 0.0))

        let request = try #require(http.observed.all.first)
        let body = try #require(request.httpBody)
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let outgoing = try #require(decoded["messages"] as? [[String: Any]])
        let toolCalls = try #require((outgoing[1])["tool_calls"] as? [[String: Any]])
        let extraContent = try #require(toolCalls[0]["extra_content"] as? [String: Any])
        let google = try #require(extraContent["google"] as? [String: Any])
        #expect(google["thought_signature"] as? String == "SIG-xyz")
    }

    // MARK: - Tool wire-name sanitization (dot-namespaced tool IDs)

    /// Regression: OpenAI's chat/completions enforces the same
    /// `^[a-zA-Z0-9_-]+$` function-name pattern as the Responses API, so
    /// Super's `time.now`-style tool IDs must be sanitized on the wire.
    @Test func dotNamespacedToolNameIsSanitizedInToolDefinitions() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-plain"))
        _ = try await collect(makeProvider(http: http).stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model, tools: [.dotNamedTimeTool], temperature: 0.5
        ))
        let request = try #require(http.observed.all.first)
        let body = try #require(request.httpBody)
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tools = try #require(decoded["tools"] as? [[String: Any]])
        let function = try #require(tools[0]["function"] as? [String: Any])
        #expect(function["name"] as? String == "time_now")
    }

    @Test func dotNamespacedHistoryToolCallEncodesTheSanitizedWireName() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-plain"))
        let messages: [LLMMessage] = [
            LLMMessage(role: .user, text: "time?"),
            LLMMessage(role: .assistant, content: [
                .toolUse(id: "call_abc", name: "time.now",
                         input: .object(["timezone": .string("UTC")]), signature: nil),
            ]),
            LLMMessage(role: .tool, content: [
                .toolResult(toolUseID: "call_abc", content: "12:00 UTC", isError: false),
            ]),
        ]
        _ = try await collect(makeProvider(http: http).stream(
            messages: messages, model: model, tools: [.dotNamedTimeTool], temperature: 0.0
        ))
        let request = try #require(http.observed.all.first)
        let body = try #require(request.httpBody)
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let outgoing = try #require(decoded["messages"] as? [[String: Any]])
        let toolCalls = try #require((outgoing[1])["tool_calls"] as? [[String: Any]])
        let function = try #require(toolCalls[0]["function"] as? [String: Any])
        #expect(function["name"] as? String == "time_now")
    }

    @Test func streamedToolCallNameIsRestoredToTheRegistryName() async throws {
        let http = FakeHTTPClient.fromFixture(FixtureLoader.load("openai-toolcall-dotname"))
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

    private func collectErrorRun(error: Error) async throws -> [LLMStreamEvent] {
        let http = FakeHTTPClient(chunks: [], error: error)
        let provider = makeProvider(http: http)
        return try await collect(provider.stream(
            messages: [LLMMessage(role: .user, text: "hi")],
            model: model,
            tools: [],
            temperature: 0.5
        ))
    }

    /// Compact one-token-per-event label so an expected-vs-actual mismatch
    /// is human-readable.
    private func eventKind(_ event: LLMStreamEvent) -> String {
        switch event {
        case .messageStart: return "messageStart"
        case .contentBlockStart(_, .text): return "contentBlockStart(text)"
        case .contentBlockStart(_, .thinking): return "contentBlockStart(thinking)"
        case .contentBlockStart(_, .toolUse): return "contentBlockStart(toolUse)"
        case .textDelta: return "textDelta"
        case .thinkingDelta: return "thinkingDelta"
        case .thinkingSignature: return "thinkingSignature"
        case .toolUse: return "toolUse"
        case .contentBlockStop(let index): return "contentBlockStop(\(index))"
        case .searchStarted: return "searchStarted"
        case .citations: return "citations"
        case .searchSuggestionsHTML: return "searchSuggestionsHTML"
        case .messageComplete: return "messageComplete"
        case .error: return "error"
        }
    }
}
