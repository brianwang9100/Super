import Core
import Foundation

/// Gemini's native adapter. It preserves tool-call thought signatures and the
/// unmodified Search Suggestions HTML required for grounded responses.
public struct GeminiNativeLLMProvider: LLMProvider {
    public let id: String
    public let displayName: String
    public let supportedModels: [LLMModel]

    private let baseURL: URL
    private let apiKey: String?
    private let http: HTTPClient

    /// Gemini accepts temperatures in `[0.0, 2.0]`; clamp rather than reject.
    private static let temperatureRange: ClosedRange<Double> = 0.0...2.0

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

    /// Requires a native Gemini configuration with a base URL.
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

    /// Skips unmodeled SSE frames; typed stream and transport errors still surface.
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
        // Keep credentials out of URLs and reject unsafe cleartext destinations.
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

    /// Hoists system instructions, merges adjacent roles, and replays only
    /// Gemini-minted call IDs; fabricated IDs must never reach the API.
    private func translate(_ messages: [LLMMessage]) -> (systemInstruction: GeminiContent?, contents: [GeminiContent]) {
        var systemParts: [String] = []
        var grouped: [(role: String, parts: [GeminiPart])] = []

        // A `.toolResult` carries only the call id; recover the function name
        // (a required `functionResponse` field) by matching it back to the
        // assistant `.toolUse` block that issued the call. A call id is sent on
        // the wire only when Gemini minted it: bare-name fallbacks (older
        // id-less turns, `id == name`) and locally-minted ids (disambiguated
        // PKs the orchestrator created because the provider gave none) are
        // synthetic — Gemini round-trips the ids IT minted, so a fabricated id
        // must not reach it; those send name-only (byte-identical to a native
        // id-less turn). See `sendsNameOnly` and the `wireID` guards below.
        func sendsNameOnly(id: String, name: String) -> Bool {
            id == name || ToolCallRecord.isLocallyMintedID(id)
        }

        var toolNameByID: [String: String] = [:]
        for message in messages where message.role == .assistant {
            for block in message.content {
                if case .toolUse(let id, let name, _, _) = block {
                    toolNameByID[id] = name
                }
            }
        }

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
                        let name = toolNameByID[toolUseID] ?? toolUseID
                        let wireID = sendsNameOnly(id: toolUseID, name: name) ? nil : toolUseID
                        parts.append(.functionResponse(
                            id: wireID,
                            name: name,
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
                        if case .toolUse(let id, let name, let input, let signature) = block {
                            // Echo Gemini's per-call id so the next turn's
                            // functionResponse can match it; omit for synthetic
                            // ids (id-less `id == name`, or a locally-minted PK)
                            // so we never send Gemini an id it didn't mint.
                            // Replay the thinking model's `thoughtSignature` —
                            // Gemini rejects the follow-up turn with HTTP 400
                            // when it's dropped.
                            let wireID = sendsNameOnly(id: id, name: name) ? nil : id
                            parts.append(.functionCall(
                                id: wireID,
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
