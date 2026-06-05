import Core
import Foundation

/// `LLMProvider` conformer for Google's Gemini **`generateContent`** API
/// (`POST /v1beta/models/{model}:streamGenerateContent?alt=sse`) — the
/// native-web-search path for Gemini models.
///
/// The default (non-search) Gemini path stays on `OpenAICompatibleLLMProvider`
/// (via Google's `/v1beta/openai/` compat shim); this adapter is hydrated only
/// for a model whose `searchBackend == "native"`, because the shim can't carry
/// the `google_search` grounding tool or the `groundingMetadata` it returns.
/// Like every native adapter it is a *complete* provider — text, extended
/// thinking, regular client tool calls, and native search — since once a turn
/// is on `generateContent` there is no per-message fallback.
///
/// Native search is requested per-turn via the `__native_web_search__` sentinel
/// tool (see ``NativeWebSearch``); when absent, no grounding tool is attached
/// and the adapter behaves like a plain Gemini client. The grounding tool is
/// `google_search` (see ``GeminiWebSearch``).
///
/// **Search-Suggestions compliance.** Gemini returns
/// `searchEntryPoint.renderedContent` (the "Google Search Suggestions" HTML),
/// which Google's terms require be displayed *unmodified* whenever a grounded
/// response is shown. The reducer surfaces it as `.searchSuggestionsHTML`;
/// `ChatSession` persists it and `GeminiSearchSuggestionsView` renders it.
///
/// **Stream contract** matches the rest of the suite: every stream ends with
/// `.messageComplete` and never throws — failures arrive as `.error(...)`
/// immediately before the terminal event. Wire formats per the Gemini +
/// web-search references (2026-05-31); see
/// `docs/superpowers/specs/2026-05-31-native-web-search-providers-design.md` §5.2.
/// ⚠️ The extended-thinking request shape and the client-tool round-trip
/// (`functionResponse` keyed by function name) are covered by serialization
/// tests but not yet validated against the live API — both become reachable
/// only once the search sentinel + tool gate are wired (PR4).
public struct GeminiNativeLLMProvider: LLMProvider {
    public let id: String
    public let displayName: String
    public let supportedModels: [LLMModel]

    private let baseURL: URL
    private let apiKey: String?
    private let http: HTTPClient

    /// Gemini accepts temperatures in `[0.0, 2.0]`; clamp rather than reject.
    private static let temperatureRange: ClosedRange<Double> = 0.0...2.0

    /// Designated initializer.
    ///
    /// - Parameters:
    ///   - id: Stable identifier (typically the `ModelConfigurationRecord.id`).
    ///   - displayName: User-visible label shown in the model picker.
    ///   - model: The single `LLMModel` this provider routes requests to.
    ///   - baseURL: Endpoint base, e.g.
    ///     `https://generativelanguage.googleapis.com/v1beta`. The
    ///     `/models/{model}:streamGenerateContent` path is appended internally.
    ///   - apiKey: BYOK (Bring Your Own Key) credential. Sent as
    ///     `x-goog-api-key` only when the destination passes the
    ///     cleartext-safety guard.
    ///   - http: Streaming HTTP client. Tests inject a fake.
    public init(
        id: String,
        displayName: String,
        model: LLMModel,
        baseURL: URL,
        apiKey: String?,
        http: HTTPClient
    ) {
        self.id = id
        self.displayName = displayName
        self.supportedModels = [model]
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.http = http
    }

    /// Convenience that derives identity + model from a stored
    /// `ModelConfiguration`. The Keychain-backed key is resolved by the caller.
    ///
    /// Precondition: `configuration.kind == .geminiNative` and
    /// `configuration.baseURL != nil`.
    public init(configuration: ModelConfiguration, apiKey: String?, http: HTTPClient) {
        precondition(
            configuration.kind == .geminiNative,
            "GeminiNativeLLMProvider requires .geminiNative kind, got \(configuration.kind)"
        )
        guard let baseURL = configuration.baseURL else {
            preconditionFailure(
                "GeminiNativeLLMProvider requires a non-nil baseURL on the configuration"
            )
        }
        let model = LLMModel(
            id: configuration.modelID,
            displayName: configuration.name,
            supportsThinking: configuration.supportsThinking,
            supportsTools: true,
            maxContextTokens: configuration.maxContextTokens,
            searchBackend: configuration.searchBackend
        )
        self.init(
            id: configuration.id,
            displayName: configuration.name,
            model: model,
            baseURL: baseURL,
            apiKey: apiKey,
            http: http
        )
    }

    public func stream(
        messages: [LLMMessage],
        model: LLMModel,
        tools: [LLMTool],
        temperature: Double
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var reducer = GeminiStreamReducer()
                do {
                    guard supportedModels.contains(where: { $0.id == model.id }) else {
                        throw LLMError.unsupportedModel(model.id)
                    }
                    let request = try buildRequest(
                        messages: messages,
                        model: model,
                        tools: tools,
                        temperature: temperature
                    )
                    var parser = SSEParser()
                    // Gemini's JSON is already camelCase — no key strategy.
                    let decoder = JSONDecoder()

                    for try await chunk in http.stream(request) {
                        for event in parser.append(chunk) {
                            for normalized in consume(event.data, into: &reducer, with: decoder) {
                                continuation.yield(normalized)
                            }
                        }
                    }
                    for event in parser.finish() {
                        for normalized in consume(event.data, into: &reducer, with: decoder) {
                            continuation.yield(normalized)
                        }
                    }
                } catch {
                    // Same recovery shape as the other native adapters: honor the
                    // messageStart-first contract, close any open block before
                    // the error, and don't double-report when a streamed error
                    // already surfaced a more specific one.
                    let alreadyErrored = reducer.hasErrored
                    reducer.markErrored()
                    for event in reducer.flushPendingStart() {
                        continuation.yield(event)
                    }
                    for event in reducer.closeOpenBlocks() {
                        continuation.yield(event)
                    }
                    if !alreadyErrored {
                        continuation.yield(.error(mapToLLMError(error)))
                    }
                }

                for event in reducer.finish() {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Decode one SSE frame's data and feed it to the reducer. Unparseable
    /// frames are skipped rather than thrown — `streamGenerateContent` may emit
    /// keep-alive or shapes this adapter doesn't model, and a harmless one must
    /// not abort the turn. Genuine failures arrive either as a non-2xx HTTP
    /// status (the catch path) or a streamed `error` envelope the reducer maps
    /// to `.error`.
    private func consume(
        _ data: String,
        into reducer: inout GeminiStreamReducer,
        with decoder: JSONDecoder
    ) -> [LLMStreamEvent] {
        guard let parsed = try? decoder.decode(GeminiStreamResponse.self, from: Data(data.utf8)) else {
            return []
        }
        return reducer.consume(parsed)
    }

    private func buildRequest(
        messages: [LLMMessage],
        model: LLMModel,
        tools: [LLMTool],
        temperature: Double
    ) throws -> URLRequest {
        let url = streamURL(modelID: model.id)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Gemini authenticates with the `x-goog-api-key` header (preferred over
        // a `?key=` query param so the key stays out of URLs/logs). Same
        // cleartext guard the other adapters use.
        if let apiKey, !apiKey.isEmpty, isCleartextSafeForCredentials(url) {
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }

        let clampedTemperature = min(
            max(temperature, Self.temperatureRange.lowerBound),
            Self.temperatureRange.upperBound
        )
        // Gemini accepts `temperature` alongside thinking (unlike Anthropic), so
        // it is always sent. `thinkingConfig` is added only for thinking models.
        let thinkingConfig = model.supportsThinking
            ? GeminiGenerateContentRequest.ThinkingConfig(includeThoughts: true)
            : nil
        let (systemInstruction, contents) = translate(messages)
        let body = GeminiGenerateContentRequest(
            contents: contents,
            systemInstruction: systemInstruction,
            generationConfig: GeminiGenerateContentRequest.GenerationConfig(
                temperature: clampedTemperature,
                thinkingConfig: thinkingConfig
            ),
            tools: translate(tools)
        )

        let encoder = JSONEncoder()
        do {
            request.httpBody = try encoder.encode(body)
        } catch {
            throw LLMError.requestFailed("encoding body: \(error.localizedDescription)")
        }
        return request
    }

    /// Build the model-scoped streaming URL. Gemini's method suffix is a literal
    /// colon segment (`{model}:streamGenerateContent`), so the URL is composed
    /// by string to keep the colon unencoded, with `alt=sse` for the SSE
    /// framing this adapter parses.
    private func streamURL(modelID: String) -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let urlString = "\(base)/models/\(modelID):streamGenerateContent?alt=sse"
        guard let url = URL(string: urlString) else {
            assertionFailure("failed to compose Gemini stream URL from \(urlString)")
            return baseURL
        }
        return url
    }

    /// Translate Chat / Core's `LLMMessage` history into Gemini's
    /// `(systemInstruction, contents)` pair. The leading `.system` block(s)
    /// become the top-level `systemInstruction` (Gemini has no system role);
    /// `.assistant` maps to role `model`; tool *results* (Core's `.tool` role)
    /// ride a `user`-role content as a `functionResponse` part (Gemini has no
    /// tool role); adjacent same-role contents are merged so the user/model
    /// alternation stays clean.
    ///
    /// `.searchResult` blocks (Anthropic's encrypted-echo carrier) are ignored
    /// — Gemini grounding needs no per-turn echo to keep citations valid.
    ///
    /// ⚠️ The `functionResponse` is keyed by function *name* (Gemini matches
    /// results to calls by name, not id; the reducer mints the call id as the
    /// name to make this round-trip), and its `response` wraps the tool's string
    /// output in an object. This client-tool path is only reachable once tools
    /// are gated alongside search (PR4) and is unverified against the live API.
    private func translate(_ messages: [LLMMessage]) -> (systemInstruction: GeminiContent?, contents: [GeminiContent]) {
        var systemParts: [String] = []
        var grouped: [(role: String, parts: [GeminiPart])] = []

        func append(role: String, parts: [GeminiPart]) {
            guard !parts.isEmpty else { return }
            if let last = grouped.last, last.role == role {
                grouped[grouped.count - 1].parts.append(contentsOf: parts)
            } else {
                grouped.append((role, parts))
            }
        }

        for message in messages {
            switch message.role {
            case .system:
                for block in message.content {
                    if case .text(let value) = block, !value.isEmpty {
                        systemParts.append(value)
                    }
                }
            case .tool:
                var parts: [GeminiPart] = []
                for block in message.content {
                    if case .toolResult(let toolUseID, let content, _) = block {
                        parts.append(.functionResponse(
                            name: toolUseID,
                            response: .object(["result": .string(content)])
                        ))
                    }
                }
                append(role: "user", parts: parts)
            case .user, .assistant:
                let role = message.role == .assistant ? "model" : "user"
                var parts: [GeminiPart] = []
                let texts = message.content.compactMap { block -> String? in
                    if case .text(let value) = block { return value }
                    return nil
                }
                let joined = texts.joined()
                if !joined.isEmpty {
                    parts.append(.text(joined))
                }
                // Tool calls are assistant-only; a stray `.toolUse` on a user
                // message must not become a `functionCall` at the user position.
                if message.role == .assistant {
                    for block in message.content {
                        if case .toolUse(_, let name, let input, let signature) = block {
                            // Replay the thinking model's `thoughtSignature` on the
                            // functionCall part — Gemini rejects the follow-up turn
                            // with HTTP 400 when it's dropped.
                            parts.append(.functionCall(
                                name: name,
                                args: input,
                                thoughtSignature: signature
                            ))
                        }
                    }
                }
                append(role: role, parts: parts)
            }
        }

        let systemInstruction = systemParts.isEmpty
            ? nil
            : GeminiContent(role: nil, parts: [.text(systemParts.joined(separator: "\n\n"))])
        return (systemInstruction, grouped.map { GeminiContent(role: $0.role, parts: $0.parts) })
    }

    /// Translate advertised tools into Gemini tools. The
    /// `__native_web_search__` sentinel becomes the `google_search` grounding
    /// tool; every other tool becomes a `functionDeclarations` entry. Returns
    /// `nil` when there are no tools so the key is omitted entirely.
    ///
    /// Note: some Gemini models reject combining `google_search` with
    /// `functionDeclarations` in one request. Per the spec decision the gated
    /// re-issue flow (PR4) ensures a search turn carries no client tools, so the
    /// two shouldn't co-occur in practice; both are still serialized here rather
    /// than silently dropping client tools.
    private func translate(_ tools: [LLMTool]) -> [GeminiTool]? {
        let (clientTools, searchEnabled) = NativeWebSearch.partition(tools)
        var out: [GeminiTool] = []
        if !clientTools.isEmpty {
            out.append(.functionDeclarations(clientTools.map { tool in
                GeminiFunctionDeclaration(
                    name: tool.name,
                    description: tool.description,
                    parameters: JSONToolSchema.parametersObject(for: tool.parameters)
                )
            }))
        }
        if searchEnabled {
            out.append(.googleSearch)
        }
        return out.isEmpty ? nil : out
    }

    /// Coerce any thrown error into an `LLMError`, normalizing cancellation the
    /// same way the other adapters do.
    private func mapToLLMError(_ error: Error) -> LLMError {
        if Task.isCancelled { return .cancelled }
        if error is CancellationError { return .cancelled }
        if let llmError = error as? LLMError { return llmError }
        if let urlError = error as? URLError, urlError.code == .cancelled { return .cancelled }
        if let httpError = error as? HTTPError { return mapHTTPError(httpError) }
        return .requestFailed(error.localizedDescription)
    }

    private func mapHTTPError(_ httpError: HTTPError) -> LLMError {
        switch httpError {
        case .badStatus(401, _), .badStatus(403, _):
            return .unauthorized
        case .badStatus(429, _):
            return .rateLimited
        case .badStatus(let code, let body):
            return .providerError(
                code: "\(code)",
                message: body.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(body)"
            )
        case .invalidResponse:
            return .requestFailed("invalid response")
        case .transport(let message):
            return .requestFailed(message)
        }
    }
}
