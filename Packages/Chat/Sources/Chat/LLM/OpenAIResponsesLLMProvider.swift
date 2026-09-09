import Core
import Foundation

/// OpenAI Responses adapter for reasoning summaries and native web search.
public struct OpenAIResponsesLLMProvider: LLMProvider {
    public let id: String
    public let displayName: String
    public let supportedModels: [LLMModel]

    private let baseURL: URL
    private let apiKey: String?
    private let http: HTTPClient

    /// OpenAI accepts temperatures in `[0.0, 2.0]`; clamp rather than reject.
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

    /// Requires an OpenAI Responses configuration with a base URL.
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
        stream(messages: messages, model: model, tools: tools, temperature: temperature, options: .none)
    }

    public func stream(
        messages: [LLMMessage],
        model: LLMModel,
        tools: [LLMTool],
        temperature: Double,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var reducer = OpenAIResponsesStreamReducer(requiresCompleteResponse: options.requiresCompleteResponse)
                // Encode dotted tool IDs for OpenAI's [A-Za-z0-9_-] wire names; restore them on decoded events.
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
                        nameMap: nameMap,
                        options: options
                    )
                    var parser = SSEParser()
                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase

                    for try await chunk in http.stream(request) {
                        for event in parser.append(chunk) {
                            for normalized in consume(event.data, into: &reducer, with: decoder) {
                                continuation.yield(nameMap.restoringToolName(in: normalized))
                            }
                        }
                    }
                    for event in parser.finish() {
                        for normalized in consume(event.data, into: &reducer, with: decoder) {
                            continuation.yield(nameMap.restoringToolName(in: normalized))
                        }
                    }
                } catch {
                    // Flush a deferred start before failure. Preserve the specific provider error and suppress secondary decode errors.
                    let alreadyErrored = reducer.hasErrored
                    reducer.markErrored()
                    for event in reducer.flushPendingStart() {
                        continuation.yield(event)
                    }
                    // Close blocks before error so the terminal completion follows it directly.
                    for event in reducer.closeOpenBlocks() {
                        continuation.yield(event)
                    }
                    if !alreadyErrored {
                        continuation.yield(.error(mapToLLMError(error)))
                    }
                }

                for event in reducer.finish() {
                    continuation.yield(nameMap.restoringToolName(in: event))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Tolerates unmodeled events; strict completion mode surfaces malformed frames as errors.
    private func consume(
        _ data: String,
        into reducer: inout OpenAIResponsesStreamReducer,
        with decoder: JSONDecoder
    ) -> [LLMStreamEvent] {
        guard let parsed = try? decoder.decode(OpenAIResponsesStreamEvent.self, from: Data(data.utf8)) else {
            guard reducer.requiresCompleteResponse, !reducer.hasErrored else { return [] }
            var events = reducer.flushPendingStart()
            events.append(contentsOf: reducer.closeOpenBlocks())
            reducer.markErrored()
            events.append(.error(.decodingFailed("Malformed streaming response frame.")))
            return events
        }
        return reducer.consume(parsed)
    }

    private func buildRequest(
        messages: [LLMMessage],
        model: LLMModel,
        tools: [LLMTool],
        temperature: Double,
        nameMap: ToolWireNameMap,
        options: LLMRequestOptions
    ) throws -> URLRequest {
        let url = responsesURL()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Never send credentials to an unsafe cleartext endpoint.
        if let apiKey, !apiKey.isEmpty, isCleartextSafeForCredentials(url) {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        // Only OpenAI hosts receive prompt_cache_key; all other request bodies remain unchanged.
        var promptCacheKey: String?
        if case .promptCacheKeyBody(let key) = CacheRoutingKey.placement(
            for: url, conversationCacheKey: options.conversationCacheKey
        ) {
            promptCacheKey = key
        }

        let clampedTemperature = min(
            max(temperature, Self.temperatureRange.lowerBound),
            Self.temperatureRange.upperBound
        )
        let (instructions, input) = try translate(messages, nameMap: nameMap)
        let body = OpenAIResponsesRequest(
            model: model.id,
            input: input,
            instructions: instructions,
            stream: true,
            temperature: clampedTemperature,
            tools: translate(tools, nameMap: nameMap),
            promptCacheKey: promptCacheKey
        )

        let encoder = JSONEncoder()
        do {
            request.httpBody = try encoder.encode(body)
        } catch {
            throw LLMError.requestFailed("encoding body: \(error.localizedDescription)")
        }
        return request
    }

    private func responsesURL() -> URL {
        let suffix = "/responses"
        // Release ignores assertionFailure; append only when absent to avoid a /responses/responses fallback.
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

    /// Hoists the leading system message to instructions; tool calls/results correlate through provider call_id.
    private func translate(
        _ messages: [LLMMessage],
        nameMap: ToolWireNameMap
    ) throws -> (instructions: String?, input: [OpenAIResponsesInputItem]) {
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
                // Responses rejects function_call items at user positions.
                if message.role == .assistant {
                    for block in message.content {
                        guard case .toolUse(let id, let name, let toolInput, _) = block else { continue }
                        let argsData = try argsEncoder.encode(toolInput)
                        let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
                        input.append(.functionCall(
                            callID: id,
                            name: nameMap.wireName(forOriginal: name),
                            argumentsJSON: argsJSON
                        ))
                    }
                }
            }
        }

        let instructions = instructionParts.isEmpty ? nil : instructionParts.joined(separator: "\n\n")
        return (instructions, input)
    }

    /// The native-search sentinel becomes a server tool. No tools omits the key entirely.
    private func translate(_ tools: [LLMTool], nameMap: ToolWireNameMap) -> [OpenAIResponsesTool]? {
        let (clientTools, searchEnabled) = NativeWebSearch.partition(tools)
        var out: [OpenAIResponsesTool] = clientTools.map { tool in
            .function(
                name: nameMap.wireName(forOriginal: tool.name),
                description: tool.description,
                parameters: JSONToolSchema.parametersObject(for: tool.parameters)
            )
        }
        if searchEnabled {
            out.append(.webSearch)
        }
        return out.isEmpty ? nil : out
    }

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
