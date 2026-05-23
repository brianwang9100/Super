import FoundationModels
import Foundation
import Testing
import os
@testable import Core

/// Tests for `AppleFoundationLLMProvider` streaming, error mapping, and
/// transcript translation, all exercised against a scripted
/// `LanguageSession` fake. The real `LanguageModelSession` would require
/// Apple Intelligence to be enabled on the host, so the suite never
/// constructs one.
@Suite
struct AppleFoundationLLMProviderTests {

    /// Model used by every test that streams. Matches the provider's
    /// `supportedModels` by `id`; `supportsTools` is irrelevant on the
    /// way *in* (the provider only checks ids) so we hard-code false.
    private static let model = LLMModel(
        id: AppleFoundationLLMProvider.defaultModelID,
        displayName: AppleFoundationLLMProvider.defaultModelDisplayName,
        supportsThinking: false,
        supportsTools: false,
        maxContextTokens: AppleFoundationLLMProvider.defaultMaxContextTokens
    )

    @Test
    func happyPathStreamYieldsMonotonicTextDeltas() async throws {
        let session = MockLanguageSession(outcome: .snapshots(["Hello", "Hello world"]))
        let provider = AppleFoundationLLMProvider(
            availability: .available,
            sessionFactory: { _, _ in session }
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
    func emptySnapshotStreamYieldsNoContentBlockAndStillCompletes() async throws {
        let session = MockLanguageSession(outcome: .snapshots([]))
        let provider = AppleFoundationLLMProvider(
            availability: .available,
            sessionFactory: { _, _ in session }
        )

        let events = try await collect(provider.stream(
            messages: [.init(role: .user, text: "hi")],
            model: Self.model,
            tools: [],
            temperature: 0.5
        ))

        #expect(!events.contains { if case .textDelta = $0 { return true }; return false })
        // No content arrived, so contentBlockStart never fired and
        // contentBlockStop never pairs with it.
        #expect(!events.contains { if case .contentBlockStart = $0 { return true }; return false })
        #expect(!events.contains { if case .contentBlockStop = $0 { return true }; return false })
        // messageStart still bookends the stream — contract holds.
        guard case .messageStart = events.first else {
            Issue.record("expected messageStart first, got \(events.first as Any)")
            return
        }
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    @Test
    func nonPrefixSnapshotIsDroppedToAvoidDoubleRender() async throws {
        // If Apple's stream ever violates monotonicity, the diff fallback
        // drops the new snapshot rather than yielding it whole — additive
        // consumers (the Chat UI streaming overlay, persistence) would
        // otherwise render the prior text twice.
        let session = MockLanguageSession(outcome: .snapshots(["Hello world", "completely different"]))
        let provider = AppleFoundationLLMProvider(
            availability: .available,
            sessionFactory: { _, _ in session }
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
        // Only the first (monotonic) snapshot survives as a delta.
        #expect(deltas == ["Hello world"])
    }

    @Test
    func duplicateSnapshotProducesNoExtraDelta() async throws {
        let session = MockLanguageSession(outcome: .snapshots(["Hi", "Hi", "Hi there"]))
        let provider = AppleFoundationLLMProvider(
            availability: .available,
            sessionFactory: { _, _ in session }
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

    @Test(arguments: AppleFoundationAvailability.Reason.allCases)
    func unavailableProviderRejectsStreamWithStableErrorCode(
        reason: AppleFoundationAvailability.Reason
    ) async throws {
        let session = MockLanguageSession(outcome: .snapshots(["unreachable"]))
        let provider = AppleFoundationLLMProvider(
            availability: .unavailable(reason),
            sessionFactory: { _, _ in session }
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
        #expect(code == reason.errorCode)
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
        #expect(!events.contains { if case .textDelta = $0 { return true }; return false })
    }

    @Test
    func unsupportedModelYieldsMessageStartThenErrorThenComplete() async throws {
        let session = MockLanguageSession(outcome: .snapshots(["x"]))
        let provider = AppleFoundationLLMProvider(
            availability: .available,
            sessionFactory: { _, _ in session }
        )
        let bogus = LLMModel(id: "not-the-system-default", displayName: "Bogus")

        let events = try await collect(provider.stream(
            messages: [.init(role: .user, text: "hi")],
            model: bogus,
            tools: [],
            temperature: 0.5
        ))

        // Pre-stream failure produces the minimum 3-event shape:
        // messageStart → error → messageComplete. No content block.
        guard case .messageStart(_, let modelId) = events.first else {
            Issue.record("expected messageStart first, got \(events.first as Any)")
            return
        }
        #expect(modelId == "not-the-system-default")
        #expect(!events.contains { if case .contentBlockStart = $0 { return true }; return false })
        #expect(!events.contains { if case .contentBlockStop = $0 { return true }; return false })
        #expect(events.contains(.error(.unsupportedModel("not-the-system-default"))))
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    @Test
    func missingTrailingUserMessageYieldsRequestFailed() async throws {
        let session = MockLanguageSession(outcome: .snapshots(["x"]))
        let provider = AppleFoundationLLMProvider(
            availability: .available,
            sessionFactory: { _, _ in session }
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
    func midStreamGenerationErrorClosesContentBlockBeforeErrorAndComplete() async throws {
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "test")
        let session = MockLanguageSession(outcome: .snapshotsThenError(
            ["partial"],
            LanguageModelSession.GenerationError.exceededContextWindowSize(context)
        ))
        let provider = AppleFoundationLLMProvider(
            availability: .available,
            sessionFactory: { _, _ in session }
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
        // Every contentBlockStart must pair with contentBlockStop, even
        // when the stream ends in error. The stop precedes the error so
        // additive consumers see a clean block-close before the failure.
        let startCount = events.filter { if case .contentBlockStart = $0 { return true }; return false }.count
        let stopCount = events.filter { if case .contentBlockStop = $0 { return true }; return false }.count
        #expect(startCount == 1)
        #expect(stopCount == 1)
        let stopIndex = events.firstIndex { if case .contentBlockStop = $0 { return true }; return false }
        let errorIndex = events.firstIndex { if case .error = $0 { return true }; return false }
        #expect(stopIndex != nil && errorIndex != nil && stopIndex! < errorIndex!)
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
            sessionFactory: { _, _ in session }
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
            sessionFactory: { _, _ in session }
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
            sessionFactory: { transcript, _ in
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
            sessionFactory: { transcript, _ in
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
    func providerWithRegistryBuildsOneDynamicLLMToolPerAdvertisedTool() async throws {
        let registry = ToolRegistry()
        await registry.register(ToolRegistration(
            tool: testToolDescriptor(id: "alpha"),
            execution: .local(ScriptedToolExecutor(toolID: "alpha", content: "")),
            isEnabled: true
        ))
        await registry.register(ToolRegistration(
            tool: testToolDescriptor(id: "beta"),
            execution: .local(ScriptedToolExecutor(toolID: "beta", content: "")),
            isEnabled: true
        ))
        let recorder = ToolsRecorder()
        let provider = AppleFoundationLLMProvider(
            availability: .available,
            sessionFactory: { _, tools in
                recorder.record(tools)
                return MockLanguageSession(outcome: .snapshots(["ok"]))
            },
            toolRegistry: registry
        )

        _ = try await collect(provider.stream(
            messages: [.init(role: .user, text: "hi")],
            model: Self.model,
            tools: [testToolDescriptor(id: "alpha"), testToolDescriptor(id: "beta")],
            temperature: 0.5
        ))

        // Factory receives exactly the two wrapped tools the orchestrator
        // advertised — registry-built `DynamicLLMTool` instances exposing
        // `name` from each `LLMTool`.
        let captured = recorder.allCalls
        #expect(captured.count == 1)
        let toolNames = captured[0].map(\.name).sorted()
        #expect(toolNames == ["alpha", "beta"])
    }

    @Test
    func supportedModelsAdvertisesToolsBasedOnRegistryPresence() async {
        let registry = ToolRegistry()
        let withRegistry = AppleFoundationLLMProvider(
            availability: .available,
            sessionFactory: { _, _ in MockLanguageSession(outcome: .snapshots([])) },
            toolRegistry: registry
        )
        let withoutRegistry = AppleFoundationLLMProvider(
            availability: .available,
            sessionFactory: { _, _ in MockLanguageSession(outcome: .snapshots([])) }
        )
        #expect(withRegistry.supportedModels.first?.supportsTools == true)
        #expect(withoutRegistry.supportedModels.first?.supportsTools == false)
        // Both still expose the same model id, so the orchestrator's
        // id-based `supportedModels.contains` lookup keeps working
        // whichever path the bootstrap takes.
        #expect(withRegistry.supportedModels.first?.id
                == AppleFoundationLLMProvider.defaultModelID)
        #expect(withoutRegistry.supportedModels.first?.id
                == AppleFoundationLLMProvider.defaultModelID)
    }

    @Test
    func providerWithoutRegistryYieldsEmptyToolsToFactory() async throws {
        let recorder = ToolsRecorder()
        let provider = AppleFoundationLLMProvider(
            availability: .available,
            sessionFactory: { _, tools in
                recorder.record(tools)
                return MockLanguageSession(outcome: .snapshots(["ok"]))
            }
            // toolRegistry omitted — defaults to nil
        )

        _ = try await collect(provider.stream(
            messages: [.init(role: .user, text: "hi")],
            model: Self.model,
            tools: [testToolDescriptor(id: "alpha")],
            temperature: 0.5
        ))

        // No registry → no dynamic tools, even though the orchestrator
        // advertised one.
        #expect(recorder.allCalls[0].isEmpty)
    }

    @Test
    func messageIDUsesInjectedGenerator() async throws {
        let idGenerator = DeterministicIDGenerator(prefix: "afm-")
        let provider = AppleFoundationLLMProvider(
            availability: .available,
            sessionFactory: { _, _ in MockLanguageSession(outcome: .snapshots(["x"])) },
            idGenerator: idGenerator
        )
        let events = try await collect(provider.stream(
            messages: [.init(role: .user, text: "hi")],
            model: Self.model,
            tools: [],
            temperature: 0.5
        ))
        guard case .messageStart(let id, _) = events.first else {
            Issue.record("expected messageStart first")
            return
        }
        #expect(id == "afm-1")
    }

    private func testToolDescriptor(id: String) -> LLMTool {
        LLMTool(
            id: id, name: id, description: "tool \(id)",
            category: .query, parameters: [], appletId: "test"
        )
    }

    @Test
    func availabilityInitializerWrapsAppleEnum() {
        #expect(AppleFoundationAvailability(.available) == .available)
        #expect(AppleFoundationAvailability(.unavailable(.deviceNotEligible))
                == .unavailable(.deviceNotEligible))
        #expect(AppleFoundationAvailability(.unavailable(.appleIntelligenceNotEnabled))
                == .unavailable(.appleIntelligenceNotEnabled))
        #expect(AppleFoundationAvailability(.unavailable(.modelNotReady))
                == .unavailable(.modelNotReady))
    }

    @Test
    func availabilityIsAvailableHelperOnlyTrueOnAvailableCase() {
        #expect(AppleFoundationAvailability.available.isAvailable)
        #expect(!AppleFoundationAvailability.unavailable(.deviceNotEligible).isAvailable)
        #expect(!AppleFoundationAvailability.unavailable(.appleIntelligenceNotEnabled).isAvailable)
        #expect(!AppleFoundationAvailability.unavailable(.modelNotReady).isAvailable)
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
            let task = Task {
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
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Records every `Transcript` handed to the test factory so assertions
/// can verify the provider's history translation. `OSAllocatedUnfairLock`
/// gives us synchronous atomic mutation without an actor hop — required
/// because the factory closure is `@Sendable` and synchronous.
final class TranscriptRecorder: Sendable {
    private let storage = OSAllocatedUnfairLock<[Transcript]>(initialState: [])

    func record(_ transcript: Transcript) {
        storage.withLock { $0.append(transcript) }
    }

    var all: [Transcript] {
        storage.withLock { $0 }
    }
}

/// Records every `[any FoundationModels.Tool]` array handed to the test
/// factory so assertions can verify the provider built the right
/// `DynamicLLMTool` wrappers from the advertised `LLMTool` list.
final class ToolsRecorder: Sendable {
    private let storage = OSAllocatedUnfairLock<[[any FoundationModels.Tool]]>(initialState: [])

    func record(_ tools: [any FoundationModels.Tool]) {
        storage.withLock { $0.append(tools) }
    }

    var allCalls: [[any FoundationModels.Tool]] {
        storage.withLock { $0 }
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
