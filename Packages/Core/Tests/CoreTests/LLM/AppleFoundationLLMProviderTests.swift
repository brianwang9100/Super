import FoundationModels
import Foundation
import Testing
@testable import Core

/// Tests for `AppleFoundationLLMProvider` streaming, error mapping, and
/// transcript translation, all exercised against a scripted
/// `LanguageSession` fake. The real `LanguageModelSession` would require
/// Apple Intelligence to be enabled on the host, so the suite never
/// constructs one.
@Suite
struct AppleFoundationLLMProviderTests {

    private static let model = AppleFoundationLLMProvider.defaultModel

    @Test
    func happyPathStreamYieldsMonotonicTextDeltas() async throws {
        let session = MockLanguageSession(outcome: .snapshots(["Hello", "Hello world"]))
        let provider = AppleFoundationLLMProvider(
            availability: .available,
            sessionFactory: { _ in session }
        )

        let events = try await collect(provider.stream(
            messages: [.init(role: .user, text: "hi")],
            model: Self.model,
            tools: [],
            temperature: 0.7
        ))

        let deltas = events.compactMap { event -> String? in
            if case .textDelta(_, let text) = event { return text }
            return nil
        }
        #expect(deltas == ["Hello", " world"])

        // Boilerplate ordering: messageStart first, messageComplete last.
        guard case .messageStart(_, let modelId) = events.first else {
            Issue.record("expected .messageStart as first event, got \(events.first as Any)")
            return
        }
        #expect(modelId == Self.model.id)
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
        #expect(events.contains { if case .contentBlockStart = $0 { return true }; return false })
        #expect(events.contains { if case .contentBlockStop = $0 { return true }; return false })
    }

    @Test
    func emptySnapshotStreamYieldsNoDeltasAndStillCompletes() async throws {
        let session = MockLanguageSession(outcome: .snapshots([]))
        let provider = AppleFoundationLLMProvider(
            availability: .available,
            sessionFactory: { _ in session }
        )

        let events = try await collect(provider.stream(
            messages: [.init(role: .user, text: "hi")],
            model: Self.model,
            tools: [],
            temperature: 0.5
        ))

        #expect(!events.contains { if case .textDelta = $0 { return true }; return false })
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    @Test
    func duplicateSnapshotProducesNoExtraDelta() async throws {
        let session = MockLanguageSession(outcome: .snapshots(["Hi", "Hi", "Hi there"]))
        let provider = AppleFoundationLLMProvider(
            availability: .available,
            sessionFactory: { _ in session }
        )

        let events = try await collect(provider.stream(
            messages: [.init(role: .user, text: "hi")],
            model: Self.model,
            tools: [],
            temperature: 0.5
        ))
        let deltas = events.compactMap { event -> String? in
            if case .textDelta(_, let text) = event { return text }
            return nil
        }
        #expect(deltas == ["Hi", " there"])
    }

    @Test(arguments: [
        AppleFoundationAvailability.deviceNotEligible,
        .appleIntelligenceNotEnabled,
        .modelNotReady,
    ])
    func unavailableProviderRejectsStreamWithStableErrorCode(
        unavailability: AppleFoundationAvailability
    ) async throws {
        let session = MockLanguageSession(outcome: .snapshots(["unreachable"]))
        let provider = AppleFoundationLLMProvider(
            availability: unavailability,
            sessionFactory: { _ in session }
        )

        let events = try await collect(provider.stream(
            messages: [.init(role: .user, text: "hi")],
            model: Self.model,
            tools: [],
            temperature: 0.5
        ))

        let errors = events.compactMap { event -> LLMError? in
            if case .error(let e) = event { return e }
            return nil
        }
        guard case .providerError(let code, _) = errors.first else {
            Issue.record("expected providerError, got \(errors)")
            return
        }
        #expect(code == unavailability.errorCode)
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
        #expect(!events.contains { if case .textDelta = $0 { return true }; return false })
    }

    @Test
    func unsupportedModelYieldsErrorBeforeComplete() async throws {
        let session = MockLanguageSession(outcome: .snapshots(["x"]))
        let provider = AppleFoundationLLMProvider(
            availability: .available,
            sessionFactory: { _ in session }
        )
        let bogus = LLMModel(id: "not-the-system-default", displayName: "Bogus")

        let events = try await collect(provider.stream(
            messages: [.init(role: .user, text: "hi")],
            model: bogus,
            tools: [],
            temperature: 0.5
        ))

        #expect(events.contains(.error(.unsupportedModel("not-the-system-default"))))
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    @Test
    func missingTrailingUserMessageYieldsRequestFailed() async throws {
        let session = MockLanguageSession(outcome: .snapshots(["x"]))
        let provider = AppleFoundationLLMProvider(
            availability: .available,
            sessionFactory: { _ in session }
        )

        let events = try await collect(provider.stream(
            messages: [
                .init(role: .system, text: "be helpful"),
                .init(role: .assistant, text: "no user follows me"),
            ],
            model: Self.model,
            tools: [],
            temperature: 0.5
        ))

        let errors = events.compactMap { event -> LLMError? in
            if case .error(let e) = event { return e }
            return nil
        }
        guard case .requestFailed = errors.first else {
            Issue.record("expected requestFailed, got \(errors)")
            return
        }
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    @Test
    func midStreamGenerationErrorYieldsMappedErrorThenComplete() async throws {
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "test")
        let session = MockLanguageSession(outcome: .snapshotsThenError(
            ["partial"],
            LanguageModelSession.GenerationError.exceededContextWindowSize(context)
        ))
        let provider = AppleFoundationLLMProvider(
            availability: .available,
            sessionFactory: { _ in session }
        )

        let events = try await collect(provider.stream(
            messages: [.init(role: .user, text: "hi")],
            model: Self.model,
            tools: [],
            temperature: 0.5
        ))

        let deltas = events.compactMap { event -> String? in
            if case .textDelta(_, let text) = event { return text }
            return nil
        }
        #expect(deltas == ["partial"])
        #expect(events.contains(.error(.providerError(
            code: "context_window_exceeded",
            message: "Conversation exceeds the on-device model's context window."
        ))))
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    @Test(arguments: GenerationErrorCase.allCases)
    func generationErrorMapsToExpectedLLMError(testCase: GenerationErrorCase) async throws {
        let session = MockLanguageSession(outcome: .error(testCase.makeError()))
        let provider = AppleFoundationLLMProvider(
            availability: .available,
            sessionFactory: { _ in session }
        )

        let events = try await collect(provider.stream(
            messages: [.init(role: .user, text: "hi")],
            model: Self.model,
            tools: [],
            temperature: 0.5
        ))

        #expect(events.contains(.error(testCase.expectedMapping)))
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    @Test
    func cancellationErrorThrownFromSessionMapsToCancelled() async throws {
        let session = MockLanguageSession(outcome: .error(CancellationError()))
        let provider = AppleFoundationLLMProvider(
            availability: .available,
            sessionFactory: { _ in session }
        )

        let events = try await collect(provider.stream(
            messages: [.init(role: .user, text: "hi")],
            model: Self.model,
            tools: [],
            temperature: 0.5
        ))

        #expect(events.contains(.error(.cancelled)))
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    @Test
    func transcriptTranslationPreservesPriorTurnsAndOmitsTrailingUser() async throws {
        let recorder = TranscriptRecorder()
        let provider = AppleFoundationLLMProvider(
            availability: .available,
            sessionFactory: { transcript in
                recorder.record(transcript)
                return MockLanguageSession(outcome: .snapshots(["ok"]))
            }
        )

        _ = try await collect(provider.stream(
            messages: [
                .init(role: .system, text: "be helpful"),
                .init(role: .user, text: "first question"),
                .init(role: .assistant, text: "first answer"),
                .init(role: .user, text: "follow-up"),
            ],
            model: Self.model,
            tools: [],
            temperature: 0.5
        ))

        let transcripts = recorder.all
        #expect(transcripts.count == 1)
        let entries = Array(transcripts[0])
        #expect(entries.count == 3)

        guard case .instructions(let instructions) = entries[0] else {
            Issue.record("expected first entry to be instructions, got \(entries[0])")
            return
        }
        #expect(textOf(instructions.segments) == "be helpful")

        guard case .prompt(let prompt) = entries[1] else {
            Issue.record("expected second entry to be prompt, got \(entries[1])")
            return
        }
        #expect(textOf(prompt.segments) == "first question")

        guard case .response(let response) = entries[2] else {
            Issue.record("expected third entry to be response, got \(entries[2])")
            return
        }
        #expect(textOf(response.segments) == "first answer")
    }

    @Test
    func toolMessagesInPriorHistoryAreDropped() async throws {
        let recorder = TranscriptRecorder()
        let provider = AppleFoundationLLMProvider(
            availability: .available,
            sessionFactory: { transcript in
                recorder.record(transcript)
                return MockLanguageSession(outcome: .snapshots(["ok"]))
            }
        )

        _ = try await collect(provider.stream(
            messages: [
                .init(role: .user, text: "earlier"),
                .init(role: .tool, content: [
                    .toolResult(toolUseID: "x", content: "result", isError: false),
                ]),
                .init(role: .user, text: "new question"),
            ],
            model: Self.model,
            tools: [],
            temperature: 0.5
        ))

        let entries = Array(recorder.all[0])
        // Phase 3 drops tool messages; only the prior `.user` survives.
        #expect(entries.count == 1)
        if case .prompt = entries[0] {} else {
            Issue.record("expected prompt entry, got \(entries[0])")
        }
    }

    @Test
    func availabilityInitializerCollapsesAppleEnum() {
        #expect(AppleFoundationAvailability(.available) == .available)
        #expect(AppleFoundationAvailability(.unavailable(.deviceNotEligible)) == .deviceNotEligible)
        #expect(AppleFoundationAvailability(.unavailable(.appleIntelligenceNotEnabled)) == .appleIntelligenceNotEnabled)
        #expect(AppleFoundationAvailability(.unavailable(.modelNotReady)) == .modelNotReady)
    }

    // MARK: - Helpers

    private func textOf(_ segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment -> String? in
            if case .text(let textSegment) = segment { return textSegment.content }
            return nil
        }.joined()
    }
}

// MARK: - Fixtures

/// Scripted `LanguageSession` substitute. `Outcome` captures the three
/// shapes the provider tests exercise: snapshots-then-finish,
/// snapshots-then-error, and immediate-error.
struct MockLanguageSession: LanguageSession {
    enum Outcome: Sendable {
        case snapshots([String])
        case snapshotsThenError([String], any Error)
        case error(any Error)
    }

    let outcome: Outcome

    func streamResponse(
        to prompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, any Error> {
        let outcome = self.outcome
        return AsyncThrowingStream { continuation in
            Task {
                switch outcome {
                case .snapshots(let snaps):
                    for snap in snaps { continuation.yield(snap) }
                    continuation.finish()
                case .snapshotsThenError(let snaps, let error):
                    for snap in snaps { continuation.yield(snap) }
                    continuation.finish(throwing: error)
                case .error(let error):
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

/// Records every `Transcript` handed to the test factory so assertions
/// can verify the provider's history translation. Lock-backed because
/// the factory closure is `@Sendable` and may run on any executor.
final class TranscriptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var transcripts: [Transcript] = []

    func record(_ transcript: Transcript) {
        lock.lock()
        defer { lock.unlock() }
        transcripts.append(transcript)
    }

    var all: [Transcript] {
        lock.lock()
        defer { lock.unlock() }
        return transcripts
    }
}

/// Per-case fixture for the `GenerationError` → `LLMError` mapping table.
/// Constructs the framework error and the expected normalized mapping
/// the provider should yield. Lives next to the tests so adding a new
/// AFM error case requires both updating the provider and updating this
/// enum — the parameterized test would fail-build otherwise.
enum GenerationErrorCase: CaseIterable, Sendable {
    case exceededContextWindowSize
    case assetsUnavailable
    case guardrailViolation
    case unsupportedGuide
    case unsupportedLanguageOrLocale
    case decodingFailure
    case rateLimited
    case concurrentRequests
    case refusal

    func makeError() -> LanguageModelSession.GenerationError {
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "test")
        switch self {
        case .exceededContextWindowSize: return .exceededContextWindowSize(context)
        case .assetsUnavailable: return .assetsUnavailable(context)
        case .guardrailViolation: return .guardrailViolation(context)
        case .unsupportedGuide: return .unsupportedGuide(context)
        case .unsupportedLanguageOrLocale: return .unsupportedLanguageOrLocale(context)
        case .decodingFailure: return .decodingFailure(context)
        case .rateLimited: return .rateLimited(context)
        case .concurrentRequests: return .concurrentRequests(context)
        case .refusal:
            return .refusal(
                LanguageModelSession.GenerationError.Refusal(transcriptEntries: []),
                context
            )
        }
    }

    var expectedMapping: LLMError {
        switch self {
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
        }
    }
}

/// Collect all events from an `AsyncThrowingStream` into an array.
/// Wrapping in a free helper keeps each test's body focused on the
/// shape of the result rather than the iteration boilerplate.
private func collect<E: Sendable>(_ stream: AsyncThrowingStream<E, Error>) async throws -> [E] {
    var out: [E] = []
    for try await event in stream {
        out.append(event)
    }
    return out
}
