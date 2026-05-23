import FoundationModels
import Foundation

/// `LLMProvider` conformer for the on-device Apple Foundation Model (AFM)
/// exposed by the `FoundationModels` framework.
///
/// **Tooling model:** AFM invokes registered tools in-band during
/// `LanguageModelSession.streamResponse`, splicing the result back into
/// the model's context invisibly to the caller. The provider therefore
/// emits only `.textDelta` events to the outer stream — never
/// `.toolUse`. Tool execution is exercised end-to-end (model →
/// `DynamicLLMTool.call` → `ToolRegistry.execute` → registry's
/// executor) but action-card UI for AFM-driven tool calls is a later
/// phase. Other providers (`OpenAICompatibleLLMProvider`) keep yielding
/// `.toolUse` and rely on the orchestrator's executeToolCalls loop.
///
/// **Stream contract** matches `OpenAICompatibleLLMProvider`: every
/// stream ends with `.messageComplete(usage:)` and never throws.
/// Failures arrive as `.error(...)` immediately before the terminal
/// `.messageComplete`. `.contentBlockStart` is emitted lazily on the
/// first non-empty delta and `.contentBlockStop` pairs with it on
/// every exit path.
///
/// **Availability is snapshot at init.** A provider built when AFM is
/// unavailable rejects every `stream(...)` call with the captured
/// reason — toggling Apple Intelligence in Settings requires a
/// relaunch. The Settings pane reads
/// `SystemLanguageModel.default.availability` directly so the row
/// subtitle stays live.
public struct AppleFoundationLLMProvider: LLMProvider {
    public let id: String
    public let displayName: String

    private let availability: AppleFoundationAvailability
    private let sessionFactory: LanguageSessionFactory
    private let idGenerator: any IDGenerator
    /// Shared dispatcher AFM tool calls fan out through. `nil` means
    /// "no tools" — the model still streams text but never sees any
    /// callable tools. The composition root passes the real registry
    /// via `init(id:availability:toolRegistry:)`; tests can construct
    /// the provider via the internal designated init with whatever
    /// registry (or nil) they need.
    private let toolRegistry: ToolRegistry?

    /// Stable identifier for the single model surface AFM exposes.
    public static let defaultModelID = "system-default"
    /// User-facing display name.
    public static let defaultModelDisplayName = "Apple Intelligence"
    /// Context-window cap on iOS 26.0–26.3 (the hard 4096-token limit).
    /// iOS 26.4 lifts this via `SystemLanguageModel.contextSize`; we
    /// keep the conservative value until that runtime read lands.
    public static let defaultMaxContextTokens = 4_096

    /// The model surface exposed to the orchestrator. `supportsTools`
    /// reflects whether a `ToolRegistry` was wired into this provider
    /// instance — without one, AFM has no callable tools, so the
    /// orchestrator should not advertise any. Computed per-instance so
    /// the registry-less startup path is honest about its capabilities.
    public var supportedModels: [LLMModel] {
        [LLMModel(
            id: Self.defaultModelID,
            displayName: Self.defaultModelDisplayName,
            supportsThinking: false,
            supportsTools: toolRegistry != nil,
            maxContextTokens: Self.defaultMaxContextTokens
        )]
    }

    /// Designated initializer. Tests pass an explicit
    /// `AppleFoundationAvailability`, a scripted `sessionFactory`, and
    /// a `DeterministicIDGenerator` so message IDs are stable; the
    /// `init()` convenience below resolves all three from real APIs.
    init(
        availability: AppleFoundationAvailability,
        sessionFactory: @escaping LanguageSessionFactory,
        id: String = "apple-foundation",
        displayName: String = "Apple Intelligence",
        idGenerator: any IDGenerator = UUIDGenerator(),
        toolRegistry: ToolRegistry? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.availability = availability
        self.sessionFactory = sessionFactory
        self.idGenerator = idGenerator
        self.toolRegistry = toolRegistry
    }

    /// Production convenience used by the composition root.
    ///
    /// `id` must match the `ModelConfigurationRecord.id` that drives
    /// the registration, mirroring `OpenAICompatibleLLMProvider`'s
    /// behavior. `LLMProviderRegistry.setActive(id:)` looks providers
    /// up by this identifier, so registering AFM under the static
    /// `"apple-foundation"` would leave the seeded
    /// `isSelected = true` row unable to promote itself to active.
    public init(
        id: String,
        availability: AppleFoundationAvailability,
        toolRegistry: ToolRegistry? = nil
    ) {
        self.init(
            availability: availability,
            sessionFactory: { transcript, tools in
                LiveLanguageSession(session: LanguageModelSession(
                    tools: tools,
                    transcript: transcript
                ))
            },
            id: id,
            toolRegistry: toolRegistry
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
                // Always emit `.messageStart` so the contract holds even
                // for pre-stream failures.
                continuation.yield(.messageStart(id: messageID, model: model.id))
                // Lazy text-block bookkeeping: `.contentBlockStart` only
                // fires on the first non-empty delta, and
                // `.contentBlockStop` pairs with it on every exit path.
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

    /// Build one `DynamicLLMTool` per advertised `LLMTool`. A tool whose
    /// schema fails to construct (malformed parameter set) is dropped
    /// silently rather than failing the whole turn — the model loses
    /// access to that tool but other tools still work. This matches the
    /// OpenAI path's behavior, which serializes each tool independently.
    /// Returns an empty array when no `ToolRegistry` was injected — AFM
    /// streams text without any callable tools in that mode.
    private func buildDynamicTools(from tools: [LLMTool]) -> [any FoundationModels.Tool] {
        guard let registry = toolRegistry else { return [] }
        return tools.compactMap { tool in
            try? DynamicLLMTool(llmTool: tool, registry: registry)
        }
    }

    /// Pull the latest `.user` message out as the live prompt and
    /// translate everything before it into a `Transcript`. The first
    /// `.system` message becomes an `Instructions` entry; remaining
    /// `.user` and `.assistant` text becomes `Prompt`/`Response`
    /// entries. Tool-result and tool-use blocks are still dropped:
    /// AFM tool calls happen in-band and never make it onto the
    /// orchestrator's history, so a `.tool` message in `messages`
    /// would only show up if a non-AFM turn ran earlier in the same
    /// session and we're now resuming on AFM — that case is rare and
    /// the safe default is to drop it.
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

    /// Diff Apple's cumulative snapshots into a delta. The framework's
    /// stream is monotonic by contract — every snapshot starts with the
    /// previous one's content. On the (currently unobserved) non-prefix
    /// case we drop the delta entirely rather than yielding the full
    /// `current` snapshot: downstream consumers concatenate `textDelta`
    /// events additively, so re-emitting the full text would double-render
    /// everything that came before.
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

    /// Map AFM's `GenerationError` cases to the normalized `LLMError`
    /// surface every provider in Super shares. The Chat UI keys off
    /// these cases for retry/banner behavior; mapping to `providerError`
    /// with stable codes lets a follow-up PR add per-code UI without
    /// touching the provider.
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
