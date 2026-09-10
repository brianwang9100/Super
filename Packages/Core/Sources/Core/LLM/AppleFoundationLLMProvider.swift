import FoundationModels
import Foundation

/// AFM executes tools in-band; the outer stream receives text, not toolUse events.
/// Every exit emits messageComplete; errors arrive immediately before it. Text
/// blocks open lazily on nonempty output and close on exit. Availability is captured
/// at init, so changing Apple Intelligence requires rebuilding the provider.
public struct AppleFoundationLLMProvider: LLMProvider {
    public let id: String
    public let displayName: String

    private let availability: AppleFoundationAvailability
    private let sessionFactory: LanguageSessionFactory
    private let idGenerator: any IDGenerator
    private let toolRegistry: ToolRegistry?

    public static let defaultModelID = "system-default"
    public static let defaultModelDisplayName = "Apple Intelligence"
    /// Fallback window for injected/test construction; production reads the framework's live value.
    public static let defaultMaxContextTokens = 4_096

    /// Reads the framework's live window without constructing a provider.
    public static var deviceContextTokens: Int { SystemLanguageModel.default.contextSize }

    private let maxContextTokens: Int

    public var supportedModels: [LLMModel] {
        [LLMModel(
            id: Self.defaultModelID,
            displayName: Self.defaultModelDisplayName,
            supportsThinking: false,
            supportsTools: toolRegistry != nil,
            maxContextTokens: maxContextTokens
        )]
    }

    init(
        availability: AppleFoundationAvailability,
        sessionFactory: @escaping LanguageSessionFactory,
        id: String = "apple-foundation",
        displayName: String = "Apple",
        idGenerator: any IDGenerator = UUIDGenerator(),
        toolRegistry: ToolRegistry? = nil,
        maxContextTokens: Int = defaultMaxContextTokens
    ) {
        self.id = id
        self.displayName = displayName
        self.availability = availability
        self.sessionFactory = sessionFactory
        self.idGenerator = idGenerator
        self.toolRegistry = toolRegistry
        self.maxContextTokens = maxContextTokens
    }

    /// id must match the persisted model-configuration row so registry selection can resolve it.
    public init(
        id: String,
        availability: AppleFoundationAvailability,
        toolRegistry: ToolRegistry? = nil
    ) {
        let resolvedContextTokens = Self.deviceContextTokens
        self.init(
            availability: availability,
            sessionFactory: { transcript, tools in
                LiveLanguageSession(session: LanguageModelSession(
                    tools: tools,
                    transcript: transcript
                ))
            },
            id: id,
            toolRegistry: toolRegistry,
            maxContextTokens: resolvedContextTokens
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
                let messageID = idGenerator.nextID()
                // Pre-stream failures still need a message identity.
                continuation.yield(.messageStart(id: messageID, model: model.id))
                var openedBlock = false
                func closeBlockIfNeeded() {
                    if openedBlock {
                        continuation.yield(.contentBlockStop(index: 0))
                        openedBlock = false
                    }
                }
                do {
                    guard supportedModels.contains(where: { $0.id == model.id }) else {
                        throw LLMError.unsupportedModel(model.id)
                    }
                    if case .unavailable(let reason) = availability {
                        throw LLMError.providerError(
                            code: reason.errorCode,
                            message: reason.errorMessage
                        )
                    }

                    let (transcript, prompt) = try translate(messages: messages)
                    let dynamicTools = buildDynamicTools(from: tools)
                    let session = sessionFactory(transcript, dynamicTools)
                    let options = GenerationOptions(temperature: temperature)

                    var lastSnapshot = ""
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        try Task.checkCancellation()
                        let delta = diff(previous: lastSnapshot, current: snapshot)
                        if !delta.isEmpty {
                            if !openedBlock {
                                continuation.yield(.contentBlockStart(index: 0, type: .text))
                                openedBlock = true
                            }
                            continuation.yield(.textDelta(index: 0, text: delta))
                        }
                        lastSnapshot = snapshot
                    }

                    closeBlockIfNeeded()
                    continuation.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
                } catch is CancellationError {
                    closeBlockIfNeeded()
                    continuation.yield(.error(.cancelled))
                    continuation.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
                } catch {
                    closeBlockIfNeeded()
                    continuation.yield(.error(mapError(error)))
                    continuation.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Malformed tool schemas are omitted independently; no registry means text-only generation.
    private func buildDynamicTools(from tools: [LLMTool]) -> [any FoundationModels.Tool] {
        guard let registry = toolRegistry else { return [] }
        return tools.compactMap { tool in
            try? DynamicLLMTool(llmTool: tool, registry: registry)
        }
    }

    // The latest user message is the live prompt; earlier text becomes transcript history.
    // Tool/thinking blocks are omitted, including history from other provider families.
    private func translate(messages: [LLMMessage]) throws -> (Transcript, String) {
        guard let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) else {
            throw LLMError.requestFailed("AppleFoundationLLMProvider requires a trailing user message")
        }
        let prior = messages[..<lastUserIndex]
        let prompt = textContent(of: messages[lastUserIndex])

        var entries: [Transcript.Entry] = []
        for message in prior {
            let text = textContent(of: message)
            guard !text.isEmpty else { continue }
            switch message.role {
            case .system:
                entries.append(.instructions(Transcript.Instructions(
                    segments: [.text(Transcript.TextSegment(content: text))],
                    toolDefinitions: []
                )))
            case .user:
                entries.append(.prompt(Transcript.Prompt(
                    segments: [.text(Transcript.TextSegment(content: text))]
                )))
            case .assistant:
                entries.append(.response(Transcript.Response(
                    assetIDs: [],
                    segments: [.text(Transcript.TextSegment(content: text))]
                )))
            case .tool:
                continue
            }
        }
        return (Transcript(entries: entries), prompt)
    }

    private func textContent(of message: LLMMessage) -> String {
        message.content.compactMap { block -> String? in
            if case .text(let value) = block { return value }
            return nil
        }.joined()
    }

    // Consumers concatenate deltas; replaying a non-prefix snapshot would duplicate prior text.
    private func diff(previous: String, current: String) -> String {
        guard current.hasPrefix(previous) else { return "" }
        return String(current.dropFirst(previous.count))
    }

    private func mapError(_ error: any Error) -> LLMError {
        if let llmError = error as? LLMError { return llmError }
        if let generationError = error as? LanguageModelSession.GenerationError {
            return mapGenerationError(generationError)
        }
        return .requestFailed(error.localizedDescription)
    }

    private func mapGenerationError(_ error: LanguageModelSession.GenerationError) -> LLMError {
        switch error {
        case .exceededContextWindowSize:
            return .providerError(
                code: "context_window_exceeded",
                message: "Conversation exceeds the on-device model's context window."
            )
        case .assetsUnavailable:
            return .providerError(
                code: "assets_unavailable",
                message: "Apple Intelligence assets are not yet available on this device."
            )
        case .guardrailViolation:
            return .providerError(
                code: "guardrail_violation",
                message: "The on-device model declined to respond to this prompt."
            )
        case .unsupportedGuide:
            return .providerError(
                code: "unsupported_guide",
                message: "Generation guide is not supported by the on-device model."
            )
        case .unsupportedLanguageOrLocale:
            return .providerError(
                code: "unsupported_locale",
                message: "Apple Intelligence does not support this device's language or locale."
            )
        case .decodingFailure:
            return .decodingFailed("On-device model produced output that could not be decoded.")
        case .rateLimited:
            return .rateLimited
        case .concurrentRequests:
            return .providerError(
                code: "concurrent_requests",
                message: "Another request is already in flight against the on-device model."
            )
        case .refusal:
            return .providerError(
                code: "refusal",
                message: "The on-device model refused to respond."
            )
        @unknown default:
            return .providerError(
                code: "unknown_generation_error",
                message: error.localizedDescription
            )
        }
    }
}
