import FoundationModels
import Foundation
import Testing
import os
@testable import Core

@Suite
struct AppleFoundationLLMProviderTests {

    private static let model = LLMModel(
        id: AppleFoundationLLMProvider.defaultModelID,
        displayName: AppleFoundationLLMProvider.defaultModelDisplayName,
        supportsThinking: false,
        supportsTools: false,
        maxContextTokens: AppleFoundationLLMProvider.defaultMaxContextTokens
    )

    @Test
    func injectedContextWindowSurfacesOnSupportedModel() {
        let provider = AppleFoundationLLMProvider(
            availability: .available,
            sessionFactory: { _, _ in MockLanguageSession(outcome: .snapshots([])) },
            maxContextTokens: 8_192
        )
        #expect(provider.supportedModels.count == 1)
        #expect(provider.supportedModels[0].maxContextTokens == 8_192)
    }

    @Test
    func contextWindowDefaultsToFallbackWhenNotInjected() {
        let provider = AppleFoundationLLMProvider(
            availability: .available,
            sessionFactory: { _, _ in MockLanguageSession(outcome: .snapshots([])) }
        )
        #expect(provider.supportedModels[0].maxContextTokens == AppleFoundationLLMProvider.defaultMaxContextTokens)
    }

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
        #expect(!events.contains { if case .contentBlockStart = $0 { return true }; return false })
        #expect(!events.contains { if case .contentBlockStop = $0 { return true }; return false })
        guard case .messageStart = events.first else {
            Issue.record("expected messageStart first, got \(events.first as Any)")
            return
        }
        #expect(events.last == .messageComplete(usage: TokenUsage(inputTokens: 0, outputTokens: 0)))
    }

    @Test
    func nonPrefixSnapshotIsDroppedToAvoidDoubleRender() async throws {
        // A full non-prefix snapshot would duplicate already emitted text in additive consumers.
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
        // Error exits must close any open content block before reporting failure.
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

        let captured = recorder.allCalls
        #expect(captured.count == 1)
        let toolNames = captured[0].map(\.name).sorted()
        #expect(toolNames == ["alpha", "beta"])
    }

    @Test
    func publicInitForwardsCallerSuppliedID() async {
        // Configuration ID, not a provider-family constant, drives registry selection.
        let provider = AppleFoundationLLMProvider(
            id: "row-uuid-abc",
            availability: .available,
            toolRegistry: nil
        )
        #expect(provider.id == "row-uuid-abc")
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

// Factories are synchronous Sendable closures, so recording cannot require an actor hop.
final class TranscriptRecorder: Sendable {
    private let storage = OSAllocatedUnfairLock<[Transcript]>(initialState: [])

    func record(_ transcript: Transcript) {
        storage.withLock { $0.append(transcript) }
    }

    var all: [Transcript] {
        storage.withLock { $0 }
    }
}

final class ToolsRecorder: Sendable {
    private let storage = OSAllocatedUnfairLock<[[any FoundationModels.Tool]]>(initialState: [])

    func record(_ tools: [any FoundationModels.Tool]) {
        storage.withLock { $0.append(tools) }
    }

    var allCalls: [[any FoundationModels.Tool]] {
        storage.withLock { $0 }
    }
}

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

private func collect<E: Sendable>(_ stream: AsyncThrowingStream<E, Error>) async throws -> [E] {
    var out: [E] = []
    for try await event in stream {
        out.append(event)
    }
    return out
}
