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
public struct OpenAICompatibleLLMProvider: LLMProvider {
    public let id: String
    public let displayName: String
    public let supportedModels: [LLMModel]

    private let baseURL: URL
    private let apiKey: String?
    private let http: HTTPClient

    /// Designated initializer.
    ///
    /// - Parameters:
    ///   - id: Stable identifier (typically the `ModelConfigurationRecord.id`).
    ///   - displayName: User-visible label shown in the model picker.
    ///   - model: The single `LLMModel` this provider routes requests to.
    ///   - baseURL: Endpoint base, e.g. `https://api.openai.com/v1` or
    ///     `http://127.0.0.1:1111/v1` for a local MLX server. The
    ///     `/chat/completions` path is appended internally.
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
    public init(configuration: ModelConfiguration, apiKey: String?, http: HTTPClient) {
        let model = LLMModel(
            id: configuration.modelID,
            displayName: configuration.name,
            supportsThinking: configuration.supportsThinking,
            supportsTools: true,
            maxContextTokens: configuration.maxContextTokens
        )
        self.init(
            id: configuration.id,
            displayName: configuration.name,
            model: model,
            baseURL: configuration.baseURL,
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
                    var reducer = OpenAIStreamReducer()
                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase

                    do {
                        for try await chunk in http.stream(request) {
                            for event in parser.append(chunk) {
                                if event.isDone { continue }
                                let parsed = try decode(event.data, with: decoder)
                                for normalized in try reducer.consume(parsed) {
                                    continuation.yield(normalized)
                                }
                            }
                        }
                        for event in parser.finish() {
                            if event.isDone { continue }
                            let parsed = try decode(event.data, with: decoder)
                            for normalized in try reducer.consume(parsed) {
                                continuation.yield(normalized)
                            }
                        }
                    } catch let httpError as HTTPError {
                        throw map(httpError)
                    }

                    for event in try reducer.finish() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LLMError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
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
        temperature: Double
    ) throws -> URLRequest {
        let url = baseURL.appending(path: "chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body = OpenAIChatRequest(
            model: model.id,
            messages: try translate(messages),
            stream: true,
            temperature: temperature,
            tools: tools.isEmpty ? nil : tools.map(translate),
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

    /// Translate Chat / Core's `LLMMessage` shape to the OpenAI request
    /// shape. Tool-result content blocks become their own outgoing
    /// messages because OpenAI requires one `role: "tool"` row per result;
    /// other content blocks are flattened into the message's `content`
    /// or `tool_calls` field.
    private func translate(_ messages: [LLMMessage]) throws -> [OpenAIRequestMessage] {
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
                    guard case .toolUse(let id, let name, let input) = block else { return nil }
                    let argsData = try JSONEncoder().encode(input)
                    let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
                    return OutgoingToolCall(id: id, name: name, argumentsJSON: argsJSON)
                }
                let joined = texts.joined()
                out.append(OpenAIRequestMessage(
                    role: roleString(for: message.role),
                    content: joined.isEmpty ? nil : joined,
                    toolCalls: toolUses.isEmpty ? nil : toolUses
                ))
            }
        }
        return out
    }

    private func translate(_ tool: LLMTool) -> OpenAITool {
        var properties: [String: JSONValue] = [:]
        var required: [String] = []
        for parameter in tool.parameters {
            var schema: [String: JSONValue] = [
                "type": .string(jsonSchemaType(for: parameter.type)),
                "description": .string(parameter.description),
            ]
            if let enumValues = parameter.enumValues {
                schema["enum"] = .array(enumValues.map { .string($0) })
            }
            properties[parameter.name] = .object(schema)
            if parameter.isRequired {
                required.append(parameter.name)
            }
        }
        let parameters: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ])
        return OpenAITool(function: OpenAIFunctionDefinition(
            name: tool.name,
            description: tool.description,
            parameters: parameters
        ))
    }

    /// `LLMTool.ParameterType` reuses Swift-friendly names (`bool`); JSON
    /// Schema (which OpenAI's tool spec follows) uses `boolean`. Translate
    /// at the boundary so consumers don't need to know.
    private func jsonSchemaType(for parameterType: ParameterType) -> String {
        switch parameterType {
        case .bool: return "boolean"
        case .string, .integer, .number, .array, .object: return parameterType.rawValue
        }
    }

    private func roleString(for role: LLMRole) -> String {
        switch role {
        case .system: return "system"
        case .user: return "user"
        case .assistant: return "assistant"
        case .tool: return "tool"
        }
    }

    private func map(_ httpError: HTTPError) -> LLMError {
        switch httpError {
        case .badStatus(401), .badStatus(403):
            return .unauthorized
        case .badStatus(429):
            return .rateLimited
        case .badStatus(let code):
            return .providerError(code: "\(code)", message: "HTTP \(code)")
        case .invalidResponse:
            return .requestFailed("invalid response")
        case .transport(let message):
            return .requestFailed(message)
        }
    }
}
