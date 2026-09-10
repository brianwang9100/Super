import Core
import Foundation

/// Anthropic's native Messages adapter. Search result encryption metadata and
/// signed thinking blocks must round-trip verbatim on continuation requests.
public struct AnthropicNativeLLMProvider: LLMProvider {
    public let id: String
    public let displayName: String
    public let supportedModels: [LLMModel]

    private let baseURL: URL
    private let apiKey: String?
    private let http: HTTPClient

    /// Anthropic accepts temperatures in `[0.0, 1.0]`; clamp rather than reject.
    private static let temperatureRange: ClosedRange<Double> = 0.0...1.0
    private static let maxTokensCeiling = 4096
    /// Shared with model listing so both endpoints use the same API version.
    static let anthropicVersion = "2023-06-01"
    /// Shared with model listing because Anthropic authenticates via `x-api-key`.
    static let apiKeyHeaderField = "x-api-key"

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

    /// Requires a native Anthropic configuration with a base URL.
    public init(configuration: ModelConfiguration, apiKey: String?, http: HTTPClient) {
        precondition(
            configuration.kind == .anthropicNative,
            "AnthropicNativeLLMProvider requires .anthropicNative kind, got \(configuration.kind)"
        )
        guard let baseURL = configuration.baseURL else {
            preconditionFailure(
                "AnthropicNativeLLMProvider requires a non-nil baseURL on the configuration"
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
                var reducer = AnthropicStreamReducer(requiresCompleteResponse: options.requiresCompleteResponse)
                // Encode dotted tool IDs for Anthropic's [A-Za-z0-9_-] wire names; restore them on decoded events.
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
                    // Preserve messageStart-first ordering and the original provider error; close blocks before error/completion.
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
                    continuation.yield(nameMap.restoringToolName(in: event))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Tolerates unmodeled frames such as pings; strict completion mode surfaces malformed frames as errors.
    private func consume(
        _ data: String,
        into reducer: inout AnthropicStreamReducer,
        with decoder: JSONDecoder
    ) -> [LLMStreamEvent] {
        guard let parsed = try? decoder.decode(AnthropicStreamEvent.self, from: Data(data.utf8)) else {
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
        nameMap: ToolWireNameMap
    ) throws -> URLRequest {
        let url = messagesURL()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        // Anthropic uses x-api-key; never send credentials to an unsafe cleartext endpoint.
        if let apiKey, !apiKey.isEmpty, isCleartextSafeForCredentials(url) {
            request.setValue(apiKey, forHTTPHeaderField: Self.apiKeyHeaderField)
        }

        // Anthropic requires max_tokens. Thinking needs a budget of at least 1024 below max_tokens,
        // omits temperature, and must be disabled when the last tool turn lacks replayable signed thinking.
        let maxTokens = max(1, min(model.maxContextTokens / 4, Self.maxTokensCeiling))
        let thinkingEnabled = model.supportsThinking
            && maxTokens >= 2048
            && Self.historySupportsThinkingContinuation(messages)
        let thinking = thinkingEnabled
            ? AnthropicMessagesRequest.Thinking(type: "enabled", budgetTokens: max(1024, maxTokens / 2))
            : nil
        let clampedTemperature = min(
            max(temperature, Self.temperatureRange.lowerBound),
            Self.temperatureRange.upperBound
        )
        let (system, anthropicMessages) = try translate(messages, nameMap: nameMap)
        let body = AnthropicMessagesRequest(
            model: model.id,
            maxTokens: maxTokens,
            stream: true,
            system: system,
            messages: anthropicMessages,
            temperature: thinkingEnabled ? nil : clampedTemperature,
            tools: translate(tools, nameMap: nameMap),
            thinking: thinking
        )

        let encoder = JSONEncoder()
        do {
            request.httpBody = try encoder.encode(body)
        } catch {
            throw LLMError.requestFailed("encoding body: \(error.localizedDescription)")
        }
        return request
    }

    /// Thinking-enabled tool continuation requires the last assistant turn's original signed block.
    static func historySupportsThinkingContinuation(_ messages: [LLMMessage]) -> Bool {
        guard let lastAssistant = messages.last(where: { $0.role == .assistant }) else {
            return true
        }
        let issuedToolCalls = lastAssistant.content.contains { block in
            if case .toolUse = block { return true }
            return false
        }
        guard issuedToolCalls else { return true }
        return lastAssistant.content.contains { block in
            if case .thinking(_, let signature) = block,
               let signature, !signature.isEmpty {
                return true
            }
            return false
        }
    }

    private func messagesURL() -> URL {
        let suffix = "/messages"
        func fallback() -> URL {
            baseURL.path.hasSuffix(suffix) ? baseURL : baseURL.appending(path: "messages")
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

    /// Hoists system instructions, places tool results in user turns, and merges adjacent roles.
    /// Search echoes precede assistant text. Their synthetic-ID replay still needs live provider verification.
    private func translate(
        _ messages: [LLMMessage],
        nameMap: ToolWireNameMap
    ) throws -> (system: [AnthropicSystemBlock]?, messages: [AnthropicMessage]) {
        // Cache only the contiguous stable system prefix; memories and checkpoint/history blocks remain volatile.
        var stableSystemParts: [String] = []
        var volatileSystemParts: [String] = []
        var sawVolatileSystem = false
        var grouped: [(role: String, blocks: [AnthropicContentBlock])] = []

        func append(role: String, blocks: [AnthropicContentBlock]) {
            guard !blocks.isEmpty else { return }
            if let last = grouped.last, last.role == role {
                grouped[grouped.count - 1].blocks.append(contentsOf: blocks)
            } else {
                grouped.append((role, blocks))
            }
        }

        for message in messages {
            switch message.role {
            case .system:
                // Once a volatile block appears, demote later stable hints to preserve wire order.
                let isStable = message.cacheHint == .stablePrefix && !sawVolatileSystem
                if !isStable { sawVolatileSystem = true }
                for block in message.content {
                    if case .text(let value) = block, !value.isEmpty {
                        if isStable {
                            stableSystemParts.append(value)
                        } else {
                            volatileSystemParts.append(value)
                        }
                    }
                }
            case .tool:
                var blocks: [AnthropicContentBlock] = []
                for block in message.content {
                    if case .toolResult(let toolUseID, let content, let isError) = block {
                        blocks.append(.toolResult(toolUseID: toolUseID, content: content, isError: isError))
                    }
                }
                append(role: "user", blocks: blocks)
            case .user, .assistant:
                let role = message.role == .assistant ? "assistant" : "user"
                var blocks: [AnthropicContentBlock] = []
                // Tool-loop thinking must be first, signed, and verbatim. Unsigned histories disable thinking in buildRequest.
                if message.role == .assistant {
                    for block in message.content {
                        if case .thinking(let content, let signature) = block,
                           let signature, !signature.isEmpty {
                            blocks.append(.thinking(thinking: content, signature: signature))
                        }
                    }
                }
                // Server search results must precede the citing text and may appear only in assistant turns.
                if message.role == .assistant {
                    for block in message.content {
                        if case .searchResult(let sources) = block,
                           let resultBlock = Self.webSearchToolResultBlock(for: sources) {
                            blocks.append(resultBlock)
                        }
                    }
                }
                let texts = message.content.compactMap { block -> String? in
                    if case .text(let value) = block { return value }
                    return nil
                }
                let joined = texts.joined()
                if !joined.isEmpty {
                    blocks.append(.text(joined))
                }
                // Anthropic rejects tool_use blocks in user turns.
                if message.role == .assistant {
                    for block in message.content {
                        if case .toolUse(let id, let name, let input, _) = block {
                            blocks.append(.toolUse(
                                id: id,
                                name: nameMap.wireName(forOriginal: name),
                                input: input
                            ))
                        }
                    }
                }
                append(role: role, blocks: blocks)
            }
        }

        // Legacy checkpoints can start with an assistant after system rows are hoisted; Anthropic requires a user first.
        // A trailing assistant can still fail prefill validation until the next user send.
        if grouped.first?.role == "assistant" {
            grouped.insert(
                ("user", [.text("(Conversation resumed after context compaction.)")]),
                at: 0
            )
        }

        // Anthropic renders tools before system, so this stable-system breakpoint also covers tool schemas.
        var systemBlocks: [AnthropicSystemBlock] = []
        if !stableSystemParts.isEmpty {
            systemBlocks.append(AnthropicSystemBlock(
                text: stableSystemParts.joined(separator: "\n\n"),
                cacheControl: AnthropicCacheControl()
            ))
        }
        if !volatileSystemParts.isEmpty {
            systemBlocks.append(AnthropicSystemBlock(
                text: volatileSystemParts.joined(separator: "\n\n"),
                cacheControl: nil
            ))
        }
        let system = systemBlocks.isEmpty ? nil : systemBlocks

        // Move the second cache breakpoint with conversation growth and each tool iteration.
        // Prefixes below the provider minimum leave it inert; only two of four markers are used.
        var anthropicMessages = grouped.map { AnthropicMessage(role: $0.role, content: $0.blocks) }
        if let lastMessageIndex = anthropicMessages.indices.last {
            let lastMessage = anthropicMessages[lastMessageIndex]
            if let lastBlockIndex = lastMessage.content.indices.last {
                var blocks = lastMessage.content
                blocks[lastBlockIndex] = .cached(blocks[lastBlockIndex])
                anthropicMessages[lastMessageIndex] = AnthropicMessage(
                    role: lastMessage.role,
                    content: blocks
                )
            }
        }
        return (system, anthropicMessages)
    }

    /// Replays only citations with this adapter's encrypted echo; other-provider citations are omitted.
    private static func webSearchToolResultBlock(for sources: [SourceCitation]) -> AnthropicContentBlock? {
        let echoes = sources.compactMap { source -> AnthropicContentBlock.WebSearchResultEcho? in
            guard let echo = source.providerEcho,
                  echo.kind == AnthropicWebSearch.echoKind,
                  let encrypted = echo.encryptedContent else { return nil }
            return AnthropicContentBlock.WebSearchResultEcho(
                url: source.url.absoluteString,
                title: source.title,
                encryptedContent: encrypted,
                pageAge: nil
            )
        }
        guard !echoes.isEmpty else { return nil }
        // Original server tool IDs are not persisted. Derive a repeatable ID per result set; see translate's replay caveat.
        let seed = echoes.map(\.url).joined(separator: "|")
        return .webSearchToolResult(toolUseID: "srvtoolu_\(Self.stableHash(seed))", results: echoes)
    }

    /// hashValue changes across runs; wire IDs need deterministic hashing.
    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 36)
    }

    /// The native-search sentinel becomes a server tool. No tools omits the key entirely.
    private func translate(_ tools: [LLMTool], nameMap: ToolWireNameMap) -> [AnthropicTool]? {
        let (clientTools, searchEnabled) = NativeWebSearch.partition(tools)
        var out: [AnthropicTool] = clientTools.map { tool in
            .function(
                name: nameMap.wireName(forOriginal: tool.name),
                description: tool.description,
                inputSchema: JSONToolSchema.parametersObject(for: tool.parameters)
            )
        }
        if searchEnabled {
            out.append(.webSearch(maxUses: AnthropicWebSearch.defaultMaxUses))
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
