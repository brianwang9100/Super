import Core
import Foundation

/// `LLMProvider` conformer for OpenAI's **Responses API** (`POST
/// /v1/responses`) — the native-web-search path for OpenAI models.
///
/// The default (non-search) OpenAI path stays on
/// `OpenAICompatibleLLMProvider` (`/chat/completions`); this adapter is
/// hydrated only for a model whose `searchBackend == "native"`, because the
/// Chat Completions shim can't carry the `web_search` server tool or its
/// `url_citation` annotations. Like every native adapter it is a *complete*
/// provider — text, reasoning summaries, regular client tool calls, and
/// native search — since once a turn is on the Responses API there is no
/// per-message fallback.
///
/// Native search is requested per-turn via the `__native_web_search__`
/// sentinel tool (see ``NativeWebSearch``); when absent, no server tool is
/// attached and the adapter behaves like a plain Responses client.
///
/// **Stream contract** matches the rest of the suite: every stream ends with
/// `.messageComplete` and never throws — failures arrive as `.error(...)`
/// immediately before the terminal event. Wire formats verified against the
/// Responses streaming reference (2026-05-31); see
/// `docs/superpowers/specs/2026-05-31-native-web-search-providers-design.md` §5.3.
public struct OpenAIResponsesLLMProvider: LLMProvider {
    public let id: String
    public let displayName: String
    public let supportedModels: [LLMModel]

    private let baseURL: URL
    private let apiKey: String?
    private let http: HTTPClient

    /// OpenAI accepts temperatures in `[0.0, 2.0]`; clamp rather than reject.
    private static let temperatureRange: ClosedRange<Double> = 0.0...2.0

    /// Designated initializer.
    ///
    /// - Parameters:
    ///   - id: Stable identifier (typically the `ModelConfigurationRecord.id`).
    ///   - displayName: User-visible label shown in the model picker.
    ///   - model: The single `LLMModel` this provider routes requests to.
    ///   - baseURL: Endpoint base, e.g. `https://api.openai.com/v1`. The
    ///     `/responses` path is appended internally; trailing slashes and
    ///     already-pathed URLs are normalized.
    ///   - apiKey: BYOK (Bring Your Own Key) credential. Attached as a bearer
    ///     token only when the destination passes the cleartext-safety guard.
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
    /// Precondition: `configuration.kind == .openAIResponses` and
    /// `configuration.baseURL != nil`. The boot path kind-dispatches before
    /// reaching this init, so a wrong kind is a programmer error caught here.
    public init(configuration: ModelConfiguration, apiKey: String?, http: HTTPClient) {
        precondition(
            configuration.kind == .openAIResponses,
            "OpenAIResponsesLLMProvider requires .openAIResponses kind, got \(configuration.kind)"
        )
        guard let baseURL = configuration.baseURL else {
            preconditionFailure(
                "OpenAIResponsesLLMProvider requires a non-nil baseURL on the configuration"
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
                var reducer = OpenAIResponsesStreamReducer()
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
                    decoder.keyDecodingStrategy = .convertFromSnakeCase

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
                    // Honor the messageStart-first contract: if the failure
                    // landed before any SSE arrived, flush the deferred start
                    // before the error. `finish()` below then only emits the
                    // terminal `.messageComplete`. `markErrored()` keeps that
                    // `finish()` from tacking a `.decodingFailed` onto any
                    // half-streamed tool call after this real error.
                    //
                    // Don't double-report: if an SSE `response.error` already
                    // surfaced a (more specific) error, skip this transport one
                    // — `ChatSession` keeps the *last* `.error`, so re-yielding
                    // would overwrite the meaningful provider error.
                    let alreadyErrored = reducer.hasErrored
                    reducer.markErrored()
                    for event in reducer.flushPendingStart() {
                        continuation.yield(event)
                    }
                    // Close any open block before the error so `.error` lands
                    // immediately before `.messageComplete` (which `finish()`
                    // emits next), not after a stray `.contentBlockStop`.
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
    /// frames are skipped rather than thrown: the Responses stream emits a
    /// large vocabulary of event types, and an unmodeled-but-harmless shape
    /// must not abort the turn. Genuine provider failures arrive as a typed
    /// `error`/`response.error` event, which the reducer maps to `.error`.
    private func consume(
        _ data: String,
        into reducer: inout OpenAIResponsesStreamReducer,
        with decoder: JSONDecoder
    ) -> [LLMStreamEvent] {
        guard let parsed = try? decoder.decode(OpenAIResponsesStreamEvent.self, from: Data(data.utf8)) else {
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
        let url = responsesURL()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Same belt-and-suspenders cleartext guard the compat provider uses:
        // never let a misconfigured `http://` endpoint carry the key.
        if let apiKey, !apiKey.isEmpty, isCleartextSafeForCredentials(url) {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let clampedTemperature = min(
            max(temperature, Self.temperatureRange.lowerBound),
            Self.temperatureRange.upperBound
        )
        let (instructions, input) = try translate(messages)
        let body = OpenAIResponsesRequest(
            model: model.id,
            input: input,
            instructions: instructions,
            stream: true,
            temperature: clampedTemperature,
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

    /// Resolve the request URL via `URLComponents` so trailing slashes and
    /// already-pathed inputs both canonicalize to `/.../responses`.
    private func responsesURL() -> URL {
        let suffix = "/responses"
        // Idempotent fallback for the exotic non-decomposable / non-recomposable
        // cases: `assertionFailure` is a no-op in Release, so appending
        // unconditionally would turn a URL already ending in `/responses` into
        // `…/responses/responses` (a silent 404). Append only when absent.
        func fallback() -> URL {
            baseURL.path.hasSuffix(suffix) ? baseURL : baseURL.appending(path: "responses")
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            assertionFailure("baseURL is not URL-component-decomposable: \(baseURL)")
            return fallback()
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix(suffix) {
            path += suffix
        }
        components.path = path
        guard let url = components.url else {
            assertionFailure("failed to recompose URL from \(components)")
            return fallback()
        }
        return url
    }

    /// Translate Chat / Core's `LLMMessage` history into the Responses
    /// `(instructions, input)` pair. The single leading `.system` message
    /// becomes `instructions`; user/assistant text become `message` items;
    /// assistant tool uses become `function_call` items and tool results
    /// become `function_call_output` items, correlated by the tool-use id
    /// (which the reducer set to the API `call_id`).
    private func translate(_ messages: [LLMMessage]) throws -> (instructions: String?, input: [OpenAIResponsesInputItem]) {
        let argsEncoder = JSONEncoder()
        var instructionParts: [String] = []
        var input: [OpenAIResponsesInputItem] = []

        for message in messages {
            switch message.role {
            case .system:
                for block in message.content {
                    if case .text(let value) = block, !value.isEmpty {
                        instructionParts.append(value)
                    }
                }
            case .tool:
                for block in message.content {
                    if case .toolResult(let toolUseID, let content, _) = block {
                        input.append(.functionCallOutput(callID: toolUseID, output: content))
                    }
                }
            case .user, .assistant:
                let role = message.role == .assistant ? "assistant" : "user"
                let texts = message.content.compactMap { block -> String? in
                    if case .text(let value) = block { return value }
                    return nil
                }
                let joined = texts.joined()
                if !joined.isEmpty {
                    input.append(.message(role: role, text: joined))
                }
                // Tool calls are an assistant-only concept. Guard the emission
                // so a `.user` message that (against convention) carried a
                // `.toolUse` block can't place a `function_call` at the user
                // position in `input` — the Responses API would reject that.
                if message.role == .assistant {
                    for block in message.content {
                        guard case .toolUse(let id, let name, let toolInput, _) = block else { continue }
                        let argsData = try argsEncoder.encode(toolInput)
                        let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
                        input.append(.functionCall(callID: id, name: name, argumentsJSON: argsJSON))
                    }
                }
            }
        }

        let instructions = instructionParts.isEmpty ? nil : instructionParts.joined(separator: "\n\n")
        return (instructions, input)
    }

    /// Translate advertised tools into Responses tools. The
    /// `__native_web_search__` sentinel becomes the `web_search` server tool;
    /// every other tool becomes a `function` tool. Returns `nil` when there
    /// are no tools so the key is omitted entirely.
    private func translate(_ tools: [LLMTool]) -> [OpenAIResponsesTool]? {
        let (clientTools, searchEnabled) = NativeWebSearch.partition(tools)
        var out: [OpenAIResponsesTool] = clientTools.map { tool in
            .function(
                name: tool.name,
                description: tool.description,
                parameters: JSONToolSchema.parametersObject(for: tool.parameters)
            )
        }
        if searchEnabled {
            out.append(.webSearch)
        }
        return out.isEmpty ? nil : out
    }

    /// Coerce any thrown error into an `LLMError`, normalizing cancellation
    /// the same way `OpenAICompatibleLLMProvider` does.
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
