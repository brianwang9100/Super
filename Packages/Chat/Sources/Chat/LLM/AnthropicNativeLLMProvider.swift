import Core
import Foundation

/// `LLMProvider` conformer for Anthropic's **Messages API** (`POST
/// /v1/messages`) — the native-web-search path for Claude models.
///
/// The default (non-search) Anthropic path stays on
/// `OpenAICompatibleLLMProvider` (via Anthropic's `/v1/openai/` compat shim);
/// this adapter is hydrated only for a model whose `searchBackend == "native"`,
/// because the shim can't carry the `web_search` server tool or its
/// `encrypted_content`/`encrypted_index` citations. Like every native adapter
/// it is a *complete* provider — text, extended thinking, regular client tool
/// calls, and native search — since once a turn is on the Messages API there is
/// no per-message fallback.
///
/// Native search is requested per-turn via the `__native_web_search__` sentinel
/// tool (see ``NativeWebSearch``); when absent, no server tool is attached and
/// the adapter behaves like a plain Messages client. The web-search tool ships
/// the stable `web_search_20250305` version (see ``AnthropicWebSearch``).
///
/// **Encrypted round-trip (mandatory).** Anthropic requires each prior
/// `web_search_tool_result` (with its `encrypted_content`) and citation
/// `encrypted_index` be replayed verbatim or the citation is rejected on the
/// next turn. They persist in `SourceCitation.providerEcho` →
/// `MessageAttachments.sources`; `ContextAssembler` replays them as a
/// `.searchResult` `LLMContent` block, which `translate(_:)` reconstructs into a
/// synthetic `web_search_tool_result` block before the cited text. ⚠️ That
/// replay shape is only *reachable* once the search sentinel is wired (PR4) and
/// is not verified against the live API yet — see `translate`.
///
/// **Stream contract** matches the rest of the suite: every stream ends with
/// `.messageComplete` and never throws — failures arrive as `.error(...)`
/// immediately before the terminal event. Wire formats per the Messages +
/// web-search references (2026-05-31); see
/// `docs/superpowers/specs/2026-05-31-native-web-search-providers-design.md` §5.1.
public struct AnthropicNativeLLMProvider: LLMProvider {
    public let id: String
    public let displayName: String
    public let supportedModels: [LLMModel]

    private let baseURL: URL
    private let apiKey: String?
    private let http: HTTPClient

    /// Anthropic accepts temperatures in `[0.0, 1.0]`; clamp rather than reject.
    private static let temperatureRange: ClosedRange<Double> = 0.0...1.0
    /// Hard ceiling on the derived `max_tokens` (§0 #7: `min(ctx/4, 4096)`).
    private static let maxTokensCeiling = 4096
    /// API version header value pinned per the web-search reference.
    private static let anthropicVersion = "2023-06-01"

    /// Designated initializer.
    ///
    /// - Parameters:
    ///   - id: Stable identifier (typically the `ModelConfigurationRecord.id`).
    ///   - displayName: User-visible label shown in the model picker.
    ///   - model: The single `LLMModel` this provider routes requests to.
    ///   - baseURL: Endpoint base, e.g. `https://api.anthropic.com/v1`. The
    ///     `/messages` path is appended internally; trailing slashes and
    ///     already-pathed URLs are normalized.
    ///   - apiKey: BYOK (Bring Your Own Key) credential. Sent as `x-api-key`
    ///     only when the destination passes the cleartext-safety guard.
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
    /// Precondition: `configuration.kind == .anthropicNative` and
    /// `configuration.baseURL != nil`. The boot path kind-dispatches before
    /// reaching this init, so a wrong kind is a programmer error caught here.
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
        AsyncThrowingStream { continuation in
            let task = Task {
                var reducer = AnthropicStreamReducer()
                // Anthropic restricts tool names to `[A-Za-z0-9_-]` (same as
                // OpenAI); Super's IDs are dot-namespaced. Encode the sanitized
                // wire name and restore the registry name on decoded events.
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
                    // Same recovery shape as the Responses adapter: honor the
                    // messageStart-first contract, close any open block before
                    // the error so `.error` lands immediately before the
                    // terminal `.messageComplete`, and don't double-report when
                    // an SSE `error` event already surfaced a more specific one.
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

    /// Decode one SSE frame's data and feed it to the reducer. Unparseable
    /// frames are skipped rather than thrown: the Messages stream emits a large
    /// vocabulary of event types (incl. `ping`), and an unmodeled-but-harmless
    /// shape must not abort the turn. Genuine failures arrive as a typed `error`
    /// event, which the reducer maps to `.error`.
    private func consume(
        _ data: String,
        into reducer: inout AnthropicStreamReducer,
        with decoder: JSONDecoder
    ) -> [LLMStreamEvent] {
        guard let parsed = try? decoder.decode(AnthropicStreamEvent.self, from: Data(data.utf8)) else {
            return []
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
        // Anthropic authenticates with `x-api-key`, not a bearer token. Same
        // belt-and-suspenders cleartext guard the other adapters use: never let
        // a misconfigured `http://` endpoint carry the key.
        if let apiKey, !apiKey.isEmpty, isCleartextSafeForCredentials(url) {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }

        // `max_tokens` is required by the API. Extended thinking (when the model
        // supports it and the budget fits) forces `temperature` to be omitted —
        // Anthropic rejects any value other than 1 alongside thinking — and the
        // thinking budget must be ≥ 1024 and strictly less than `max_tokens`.
        let maxTokens = max(1, min(model.maxContextTokens / 4, Self.maxTokensCeiling))
        let thinkingEnabled = model.supportsThinking && maxTokens >= 2048
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

    /// Resolve the request URL via `URLComponents` so trailing slashes and
    /// already-pathed inputs both canonicalize to `/.../messages`.
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

    /// Translate Chat / Core's `LLMMessage` history into the Messages
    /// `(system, messages)` pair. The leading `.system` block(s) become the
    /// top-level `system` string; tool *results* (Core's `.tool` role) ride a
    /// `user`-role message (Anthropic has no `tool` role); adjacent same-role
    /// messages are merged into one so the strict user/assistant alternation the
    /// API requires holds.
    ///
    /// `.searchResult` blocks (replayed prior-turn citations, attached by
    /// `ContextAssembler`) reconstruct a `web_search_tool_result` content block
    /// placed *before* the assistant's text so Anthropic accepts the citations.
    /// ⚠️ The reconstructed block carries a *synthetic* `tool_use_id` — we
    /// persist the encrypted echoes but not the original `server_tool_use` id —
    /// and this whole path is only reachable once the search sentinel is wired
    /// (PR4). Validate the accepted replay shape (incl. whether a matching
    /// `server_tool_use` block must also be replayed) against `/v1/messages`
    /// then; until then it's covered only by serialization-shape unit tests.
    private func translate(
        _ messages: [LLMMessage],
        nameMap: ToolWireNameMap
    ) throws -> (system: String?, messages: [AnthropicMessage]) {
        var systemParts: [String] = []
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
                for block in message.content {
                    if case .text(let value) = block, !value.isEmpty {
                        systemParts.append(value)
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
                // Replayed web-search results are an assistant-only, server-emitted
                // concept and must precede the text that cites them on the wire.
                // Guard on the role so the invariant is structural rather than
                // relying on `ContextAssembler` being the only caller — a stray
                // `.searchResult` on a user message would otherwise serialize a
                // `web_search_tool_result` at the user position, which the API
                // rejects. (Same posture as the assistant-only tool-call guard below.)
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
                // Tool calls are an assistant-only concept (§ guard mirrors the
                // Responses adapter): a stray `.toolUse` on a user message must
                // not become a `tool_use` block at the user position.
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

        let system = systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n")
        return (system, grouped.map { AnthropicMessage(role: $0.role, content: $0.blocks) })
    }

    /// Reconstruct a `web_search_tool_result` block from stored citations,
    /// keeping only those carrying this adapter's encrypted echo. Returns `nil`
    /// when none qualify (e.g. citations from a different provider replayed into
    /// an Anthropic turn after a model switch — harmlessly skipped).
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
        // Synthetic id: the original `server_tool_use` id isn't persisted, so
        // derive a *stable, deterministic* one from the result set (not Swift's
        // per-run-randomized `hashValue`, which would make the request payload
        // irreproducible). This also keeps replayed turns from colliding on a
        // shared constant should Anthropic ever enforce conversation-wide
        // `tool_use_id` uniqueness. ⚠️ See the `translate` note — the replay
        // shape itself is unverified until the search path is live (PR4).
        let seed = echoes.map(\.url).joined(separator: "|")
        return .webSearchToolResult(toolUseID: "srvtoolu_\(Self.stableHash(seed))", results: echoes)
    }

    /// Deterministic FNV-1a hash → base-36 string. Used to mint a reproducible
    /// synthetic `tool_use_id` for replayed search results; `hashValue` is
    /// per-run-randomized and unsuitable for a wire payload.
    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 36)
    }

    /// Translate advertised tools into Anthropic tools. The
    /// `__native_web_search__` sentinel becomes the `web_search` server tool;
    /// every other tool becomes a custom tool with an `input_schema`. Returns
    /// `nil` when there are no tools so the key is omitted entirely.
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
