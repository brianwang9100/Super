import Core
import Foundation

/// `LLMProvider` conformer for any endpoint speaking the OpenAI Chat
/// Completions API (Application Programming Interface). Targets the hosted
/// OpenAI service, DeepSeek, Together, Groq, and local servers
/// (Ollama / LM Studio / MLX) interchangeably — the wire format is
/// identical and `apiKey` is optional so unauthenticated local endpoints
/// work without ceremony.
///
/// One provider instance corresponds to one configured model. The shape
/// matches Chat's `ModelConfigurationRecord`: each saved configuration
/// instantiates one provider, and the registry holds them all.
///
/// **Stream contract**: every stream terminates with `.messageComplete`
/// and never throws. Failures (transport, decoding, cancellation, etc.)
/// arrive as `.error(...)` events immediately before the terminal
/// `.messageComplete`, so consumers always get a clean signal that the
/// stream is done and can persist whatever did make it through.
public struct OpenAICompatibleLLMProvider: LLMProvider {
    public let id: String
    public let displayName: String
    public let supportedModels: [LLMModel]

    private let baseURL: URL
    private let apiKey: String?
    private let http: HTTPClient

    /// OpenAI accepts temperatures in `[0.0, 2.0]`. Per the `LLMProvider`
    /// protocol contract, conformers are expected to clamp rather than
    /// reject out-of-range values.
    private static let temperatureRange: ClosedRange<Double> = 0.0...2.0

    /// Designated initializer.
    ///
    /// - Parameters:
    ///   - id: Stable identifier (typically the `ModelConfigurationRecord.id`).
    ///   - displayName: User-visible label shown in the model picker.
    ///   - model: The single `LLMModel` this provider routes requests to.
    ///   - baseURL: Endpoint base, e.g. `https://api.openai.com/v1` or
    ///     `http://127.0.0.1:1111/v1` for a local MLX server. The
    ///     `/chat/completions` path is appended internally; trailing
    ///     slashes and already-pathed URLs are normalized.
    ///   - apiKey: BYOK (Bring Your Own Key) credential. `nil` skips the
    ///     `Authorization` header — required for most local servers, which
    ///     otherwise reject unrecognized auth.
    ///   - http: Streaming HTTP (HyperText Transfer Protocol) client. Tests
    ///     inject a fake; production uses `URLSessionHTTPClient`.
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

    /// Convenience that derives the provider's identity and target model
    /// from a stored `ModelConfiguration`. The Keychain-backed key must be
    /// resolved by the caller (the registry layer) before construction
    /// because Core has no Keychain dependency on this path.
    ///
    /// Precondition: `configuration.kind == .openAICompatible` and
    /// `configuration.baseURL != nil`. The boot path is responsible for
    /// kind-dispatching before reaching this init — passing an
    /// `.appleFoundation` row would be a programmer error and is caught
    /// at boot rather than first-stream.
    public init(configuration: ModelConfiguration, apiKey: String?, http: HTTPClient) {
        precondition(
            configuration.kind == .openAICompatible,
            "OpenAICompatibleLLMProvider requires .openAICompatible kind, got \(configuration.kind)"
        )
        guard let baseURL = configuration.baseURL else {
            preconditionFailure(
                "OpenAICompatibleLLMProvider requires a non-nil baseURL on the configuration"
            )
        }
        let model = LLMModel(
            id: configuration.modelID,
            displayName: configuration.name,
            supportsThinking: configuration.supportsThinking,
            supportsTools: true,
            maxContextTokens: configuration.maxContextTokens,
            // Carry the row's search backend onto the vended model so the
            // turn loop sees `model.searchBackend` for a non-native model
            // (e.g. the DEBUG "debug" mock backend). The native adapters
            // stamp this from their own configurations; this path is the
            // one that was missing it.
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
                var reducer = OpenAIStreamReducer()
                // OpenAI restricts tool names to `[A-Za-z0-9_-]`; Super's IDs
                // are dot-namespaced. Encode the sanitized wire name and
                // restore the registry name on every decoded event.
                let nameMap = ToolWireNameMap(tools: tools)
                do {
                    guard supportedModels.contains(where: { $0.id == model.id }) else {
                        throw LLMError.unsupportedModel(model.id)
                    }
                    let request = try buildRequest(
                        messages: messages,
                        model: model,
                        tools: tools,
                        temperature: temperature,
                        nameMap: nameMap
                    )
                    var parser = SSEParser()
                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase

                    for try await chunk in http.stream(request) {
                        for event in parser.append(chunk) {
                            if event.isDone { continue }
                            let parsed = try decode(event.data, with: decoder)
                            for normalized in reducer.consume(parsed) {
                                continuation.yield(nameMap.restoringToolName(in: normalized))
                            }
                        }
                    }
                    for event in parser.finish() {
                        if event.isDone { continue }
                        let parsed = try decode(event.data, with: decoder)
                        for normalized in reducer.consume(parsed) {
                            continuation.yield(nameMap.restoringToolName(in: normalized))
                        }
                    }
                } catch {
                    let llmError = mapToLLMError(error)
                    continuation.yield(.error(llmError))
                }

                for event in reducer.finish() {
                    continuation.yield(nameMap.restoringToolName(in: event))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func decode(_ data: String, with decoder: JSONDecoder) throws -> OpenAIStreamChunk {
        do {
            return try decoder.decode(OpenAIStreamChunk.self, from: Data(data.utf8))
        } catch {
            throw LLMError.decodingFailed("stream chunk: \(error.localizedDescription)")
        }
    }

    private func buildRequest(
        messages: [LLMMessage],
        model: LLMModel,
        tools: [LLMTool],
        temperature: Double,
        nameMap: ToolWireNameMap
    ) throws -> URLRequest {
        let url = chatCompletionsURL()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Only attach the bearer token when the destination is HTTPS or a
        // loopback / `*.local` host. Belt-and-suspenders on top of ATS: a
        // misconfigured `http://` endpoint must not even be able to leak
        // the key in an in-flight URLRequest. See `URLSecurity.swift`.
        if let apiKey, !apiKey.isEmpty, isCleartextSafeForCredentials(url) {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let clampedTemperature = min(max(temperature, Self.temperatureRange.lowerBound), Self.temperatureRange.upperBound)
        let body = OpenAIChatRequest(
            model: model.id,
            messages: try translate(messages, nameMap: nameMap),
            stream: true,
            temperature: clampedTemperature,
            tools: tools.isEmpty ? nil : tools.map { translate($0, nameMap: nameMap) },
            streamOptions: .init(includeUsage: true)
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        do {
            request.httpBody = try encoder.encode(body)
        } catch {
            throw LLMError.requestFailed("encoding body: \(error.localizedDescription)")
        }
        return request
    }

    /// Resolve the request URL (Uniform Resource Locator). Uses
    /// `URLComponents` rather than string concatenation so trailing
    /// slashes and already-pathed inputs both produce the same canonical
    /// `/.../chat/completions` URL.
    private func chatCompletionsURL() -> URL {
        let suffix = "/chat/completions"
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            assertionFailure("baseURL is not URL-component-decomposable: \(baseURL)")
            return baseURL.appending(path: "chat/completions")
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix(suffix) {
            path += suffix
        }
        components.path = path
        guard let url = components.url else {
            assertionFailure("failed to recompose URL from \(components)")
            return baseURL.appending(path: "chat/completions")
        }
        return url
    }

    /// Translate Chat / Core's `LLMMessage` shape to the OpenAI request
    /// shape. Tool-result content blocks become their own outgoing
    /// messages because OpenAI requires one `role: "tool"` row per result;
    /// other content blocks are flattened into the message's `content`
    /// or `tool_calls` field. Messages with no usable content are dropped
    /// (with a debug-only assertion) since OpenAI rejects assistant rows
    /// that carry neither `content` nor `tool_calls`.
    private func translate(
        _ messages: [LLMMessage],
        nameMap: ToolWireNameMap
    ) throws -> [OpenAIRequestMessage] {
        let toolCallEncoder = JSONEncoder()
        var out: [OpenAIRequestMessage] = []
        for message in messages {
            switch message.role {
            case .tool:
                for block in message.content {
                    if case .toolResult(let toolUseID, let content, _) = block {
                        out.append(OpenAIRequestMessage(
                            role: "tool",
                            content: content,
                            toolCallId: toolUseID
                        ))
                    }
                }
            default:
                let texts = message.content.compactMap { block -> String? in
                    if case .text(let value) = block { return value }
                    return nil
                }
                let toolUses = try message.content.compactMap { block -> OutgoingToolCall? in
                    guard case .toolUse(let id, let name, let input, let signature) = block else { return nil }
                    let argsData = try toolCallEncoder.encode(input)
                    let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
                    // Replay Gemini's thought signature via the `extra_content`
                    // extension — the shim 400s the follow-up turn without it.
                    return OutgoingToolCall(
                        id: id,
                        name: nameMap.wireName(forOriginal: name),
                        argumentsJSON: argsJSON,
                        thoughtSignature: signature
                    )
                }
                let joined = texts.joined()
                if joined.isEmpty && toolUses.isEmpty {
                    // A thinking-only assistant turn is a legal projection
                    // (the trace persists for re-render and for Anthropic
                    // replay) that this wire format simply can't express —
                    // skip it silently. Anything else empty is a projection
                    // invariant breach worth flagging.
                    let hasThinking = message.content.contains { block in
                        if case .thinking = block { return true }
                        return false
                    }
                    if !hasThinking {
                        assertionFailure("LLMMessage with role \(message.role) has no text or tool-use content; OpenAI would reject it")
                    }
                    continue
                }
                out.append(OpenAIRequestMessage(
                    role: roleString(for: message.role),
                    content: joined.isEmpty ? nil : joined,
                    toolCalls: toolUses.isEmpty ? nil : toolUses
                ))
            }
        }
        return out
    }

    private func translate(_ tool: LLMTool, nameMap: ToolWireNameMap) -> OpenAITool {
        OpenAITool(function: OpenAIFunctionDefinition(
            name: nameMap.wireName(forOriginal: tool.name),
            description: tool.description,
            parameters: JSONToolSchema.parametersObject(for: tool.parameters)
        ))
    }

    private func roleString(for role: LLMRole) -> String {
        switch role {
        case .system: return "system"
        case .user: return "user"
        case .assistant: return "assistant"
        case .tool: return "tool"
        }
    }

    /// Coerce any thrown error into an `LLMError`. Cancellation gets
    /// special handling: `Task.isCancelled` overrides whatever the
    /// throwing site reported, because URLSession surfaces task
    /// cancellation as `URLError.cancelled` (mapped through `HTTPError`)
    /// rather than `CancellationError`, and we want a single canonical
    /// `.cancelled` regardless of source.
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
