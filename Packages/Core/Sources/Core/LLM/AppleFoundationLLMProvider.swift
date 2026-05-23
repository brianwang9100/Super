import FoundationModels
import Foundation

/// `LLMProvider` conformer for the on-device Apple Foundation Model (AFM)
/// exposed by the `FoundationModels` framework.
///
/// **Phase 3 scope:** text-only. The exposed `LLMModel` advertises
/// `supportsTools: false` and the provider drops any `tools` argument it
/// receives. Phase 4 lifts that flag and wires the `DynamicLLMTool`
/// adapter through `LanguageSession`.
///
/// **Stream contract** matches `OpenAICompatibleLLMProvider`: every
/// stream ends with `.messageComplete(usage:)` and never throws. Failures
/// (unavailable AFM, unsupported model, mid-stream `GenerationError`,
/// cancellation) arrive as `.error(...)` immediately before the terminal
/// `.messageComplete`, so consumers always get a clean stream-done signal
/// and can persist whatever did make it through.
///
/// **Availability is snapshot at init.** A provider built when AFM is
/// unavailable will reject every `stream(...)` call with the captured
/// reason — toggling Apple Intelligence in Settings requires a relaunch.
/// The Settings pane reads `SystemLanguageModel.default.availability`
/// directly so the row subtitle stays live.
public struct AppleFoundationLLMProvider: LLMProvider {
    public let id: String
    public let displayName: String
    public let supportedModels: [LLMModel]

    private let availability: AppleFoundationAvailability
    private let sessionFactory: LanguageSessionFactory

    /// The single model surface exposed by the provider. Context window
    /// is the iOS 26.0–26.3 hard cap of 4096 tokens; iOS 26.4 lifts the
    /// limit via `SystemLanguageModel.contextSize` but the lower number
    /// is the safe default until we read the runtime value.
    public static let defaultModel = LLMModel(
        id: "system-default",
        displayName: "Apple Intelligence",
        supportsThinking: false,
        supportsTools: false,
        maxContextTokens: 4_096
    )

    /// Designated initializer. Tests pass an explicit
    /// `AppleFoundationAvailability` and a scripted `sessionFactory`; the
    /// `init()` convenience below resolves both from real APIs.
    init(
        id: String = "apple-foundation",
        displayName: String = "Apple Intelligence",
        availability: AppleFoundationAvailability,
        sessionFactory: @escaping LanguageSessionFactory
    ) {
        self.id = id
        self.displayName = displayName
        self.availability = availability
        self.sessionFactory = sessionFactory
        self.supportedModels = [Self.defaultModel]
    }

    /// Production convenience. Snapshots availability from
    /// `SystemLanguageModel.default` and uses `LiveLanguageSession` for
    /// every turn. Call this from the composition root after deciding to
    /// register an AFM-backed `ModelConfiguration` row.
    public init() {
        self.init(
            availability: AppleFoundationAvailability(SystemLanguageModel.default.availability),
            sessionFactory: { transcript in
                LiveLanguageSession(session: LanguageModelSession(transcript: transcript))
            }
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
                let messageID = UUID().uuidString
                do {
                    guard supportedModels.contains(where: { $0.id == model.id }) else {
                        throw LLMError.unsupportedModel(model.id)
                    }
                    if availability != .available {
                        throw LLMError.providerError(
                            code: availability.errorCode,
                            message: availability.errorMessage
                        )
                    }

                    let (transcript, prompt) = try translate(messages: messages)
                    let session = sessionFactory(transcript)
                    let options = GenerationOptions(temperature: temperature)

                    continuation.yield(.messageStart(id: messageID, model: model.id))
                    continuation.yield(.contentBlockStart(index: 0, type: .text))

                    var lastSnapshot = ""
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        try Task.checkCancellation()
                        let delta = diff(previous: lastSnapshot, current: snapshot)
                        if !delta.isEmpty {
                            continuation.yield(.textDelta(index: 0, text: delta))
                        }
                        lastSnapshot = snapshot
                    }

                    continuation.yield(.contentBlockStop(index: 0))
                    continuation.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
                } catch is CancellationError {
                    continuation.yield(.error(.cancelled))
                    continuation.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
                } catch {
                    continuation.yield(.error(mapError(error)))
                    continuation.yield(.messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Pull the latest `.user` message out as the live prompt and
    /// translate everything before it into a `Transcript`. The first
    /// `.system` message becomes an `Instructions` entry; remaining
    /// `.user` and `.assistant` text becomes `Prompt`/`Response` entries.
    /// Tool-result and tool-use blocks are dropped in Phase 3 — Phase 4
    /// expands this once the dynamic-tool adapter lands.
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
    /// stream is monotonic by contract; the fallback yields the whole
    /// snapshot in the (currently unobserved) non-prefix case so the
    /// consumer still sees the latest text rather than silently losing
    /// content.
    private func diff(previous: String, current: String) -> String {
        if current.hasPrefix(previous) {
            return String(current.dropFirst(previous.count))
        }
        return current
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

extension AppleFoundationAvailability {
    /// Stable identifier used in `LLMError.providerError(code:...)` so
    /// the Chat UI can render a specific banner per reason without
    /// pattern-matching localized strings.
    var errorCode: String {
        switch self {
        case .available: return ""
        case .deviceNotEligible: return "afm_device_not_eligible"
        case .appleIntelligenceNotEnabled: return "afm_apple_intelligence_not_enabled"
        case .modelNotReady: return "afm_model_not_ready"
        }
    }

    var errorMessage: String {
        switch self {
        case .available: return ""
        case .deviceNotEligible:
            return "This device is not eligible for Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is not enabled in System Settings."
        case .modelNotReady:
            return "Apple Intelligence is preparing the on-device model. Try again shortly."
        }
    }
}
