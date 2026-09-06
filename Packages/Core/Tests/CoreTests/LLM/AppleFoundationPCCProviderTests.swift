import FoundationModels
import Foundation
import Testing
@testable import Core

/// Exercises the shared PCC streaming engine with injected status/session data;
/// no test initializes or sends a prompt to Apple's cloud model.
@Suite
struct AppleFoundationPCCProviderTests {
    private static let ready = AppleFoundationModelStatus(
        model: .privateCloudCompute, availability: .available, contextTokens: 32_768
    )

    @Test
    func PCCKeepsItsOwnIdentityContextAndCumulativeStreaming() async throws {
        let provider = makeProvider(session: .snapshots(["Hello", "Hello cloud"]))
        #expect(provider.supportedModels[0].id == "private-cloud-compute")
        #expect(provider.supportedModels[0].maxContextTokens == 32_768)
        #expect(!provider.supportedModels[0].supportsThinking)
        let events = try await run(provider)
        #expect(text(in: events) == ["Hello", " cloud"])
        #expect(events.first == .messageStart(id: "pcc-1", model: "private-cloud-compute"))
        #expect(events.last == .messageComplete(usage: .init(inputTokens: 0, outputTokens: 0)))
    }

    @Test
    func readinessIsRefreshedBetweenTurnsWithoutReconstructingProvider() async throws {
        let states = ScriptedAppleStatus([
            .init(model: .privateCloudCompute, availability: .unavailable(.systemNotReady)), Self.ready
        ])
        let provider = makeProvider(session: .snapshots(["Recovered"]), status: { await states.next() })
        let first = try await run(provider)
        #expect(errorCode(in: first) == "pcc_system_not_ready")
        #expect(text(in: first).isEmpty)
        let second = try await run(provider)
        #expect(text(in: second) == ["Recovered"])
        #expect(errorCode(in: second) == nil)
    }

    @Test
    func refreshedContextReplacesOnlyTheInertPlaceholder() async throws {
        let initial = AppleFoundationModelStatus(model: .privateCloudCompute, availability: .available)
        let provider = makeProvider(session: .snapshots(["ok"]), initial: initial)
        #expect(provider.supportedModels[0].maxContextTokens == 0)
        let resolved = try await provider.resolveModel(provider.supportedModels[0])
        #expect(resolved.maxContextTokens == 32_768)
        #expect(provider.supportedModels[0].maxContextTokens == 32_768)
    }

    @Test
    func quotaPreflightNeverConstructsTheSessionOrFallsBack() async throws {
        let state = AppleFoundationModelStatus(
            model: .privateCloudCompute, availability: .available, contextTokens: 32_768,
            quota: .init(state: .limitReached)
        )
        let provider = AppleFoundationLLMProvider(
            model: .privateCloudCompute, initialStatus: state, status: { state },
            sessionFactory: { _, _ in preconditionFailure("Quota-blocked generation must not create a session") }
        )
        let events = try await run(provider)
        #expect(errorCode(in: events) == "pcc_quota_limit_reached")
        #expect(events.count == 3)
        #expect(provider.supportedModels[0].id == "private-cloud-compute")
    }

    @Test
    func unresolvedContextNeverConstructsTheSession() async throws {
        let state = AppleFoundationModelStatus(model: .privateCloudCompute, availability: .available)
        let provider = AppleFoundationLLMProvider(
            model: .privateCloudCompute, initialStatus: state, status: { state },
            sessionFactory: { _, _ in preconditionFailure("Unresolved metadata must block generation") }
        )
        #expect(errorCode(in: try await run(provider)) == "apple_model_metadata_unavailable")
    }

    @Test
    func localAndUnknownModelIDsAreRejectedByPCC() async throws {
        let provider = makeProvider(session: .snapshots(["must not be used"]))
        for id in ["system-default", "unknown"] {
            let events = try await collect(provider.stream(
                messages: [.init(role: .user, text: "hi")],
                model: LLMModel(id: id, displayName: "fixture"), tools: [], temperature: 0.5
            ))
            #expect(events.contains(.error(.unsupportedModel(id))))
            #expect(text(in: events).isEmpty)
        }
    }

    @Test
    func mismatchedStatusCannotEnableAnotherBackend() async throws {
        let local = AppleFoundationModelStatus(model: .local, availability: .available, contextTokens: 4_096)
        let provider = makeProvider(session: .snapshots(["must not be used"]), status: { local })
        #expect(try await run(provider).contains(.error(.unsupportedModel("private-cloud-compute"))))
    }

    @Test
    func injectedErrorNormalizationClosesTextBeforeTerminalEvents() async throws {
        let normalized = LLMError.providerError(code: "pcc_service_unavailable", message: "fixture")
        let provider = AppleFoundationLLMProvider(
            model: .privateCloudCompute, initialStatus: Self.ready, status: { Self.ready },
            sessionFactory: { _, _ in MockLanguageSession(outcome: .snapshotsThenError(["partial"], ScriptedError.failure)) },
            normalizeError: { _ in normalized }
        )
        let events = try await run(provider)
        #expect(text(in: events) == ["partial"])
        #expect(Array(events.suffix(3)) == [
            .contentBlockStop(index: 0), .error(normalized),
            .messageComplete(usage: .init(inputTokens: 0, outputTokens: 0)),
        ])
    }

    @Test
    func cancellationPreservesTerminalContract() async throws {
        let provider = makeProvider(session: .error(CancellationError()))
        let events = try await run(provider)
        #expect(events.contains(.error(.cancelled)))
        #expect(events.last == .messageComplete(usage: .init(inputTokens: 0, outputTokens: 0)))
        #expect(text(in: events).isEmpty)
    }

    @Test
    func toolAndTranscriptBridgesAreSharedWithLocalProvider() async throws {
        let toolRecorder = ToolsRecorder()
        let transcriptRecorder = TranscriptRecorder()
        let provider = AppleFoundationLLMProvider(
            model: .privateCloudCompute, initialStatus: Self.ready, status: { Self.ready },
            sessionFactory: { transcript, tools in
                transcriptRecorder.record(transcript)
                toolRecorder.record(tools)
                return MockLanguageSession(outcome: .snapshots(["ok"]))
            },
            toolRegistry: ToolRegistry()
        )
        let tool = LLMTool(id: "lookup", name: "lookup", description: "fixture", category: .query, parameters: [], appletId: "test")
        _ = try await collect(provider.stream(
            messages: [.init(role: .system, text: "instructions"), .init(role: .user, text: "hi")],
            model: provider.supportedModels[0], tools: [tool], temperature: 0.5
        ))
        #expect(toolRecorder.allCalls[0].map(\.name) == ["lookup"])
        #expect(Array(transcriptRecorder.all[0]).count == 1)
        #expect(provider.supportedModels[0].supportsTools)
    }

    @Test
    func unknownPCCErrorsDoNotExposeDebugDescriptions() async throws {
        let provider = makeProvider(session: .error(ScriptedError.failure))
        #expect(errorCode(in: try await run(provider)) == "pcc_request_failed")
    }

    @Test(.enabled(if: supportsPCCRuntime))
    func actualPCCErrorCasesUseStableCodesAndDoNotExposeDebugContent() {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let cases: [(PrivateCloudComputeLanguageModel.Error, String)] = [
            (.networkFailure(.init(debugDescription: "private fixture content")), "pcc_network_failure"),
            (.quotaLimitReached(.init(debugDescription: "private fixture content")), "pcc_quota_limit_reached"),
            (.serviceUnavailable(.init(debugDescription: "private fixture content")), "pcc_service_unavailable"),
        ]
        for (error, expectedCode) in cases {
            guard case .providerError(let code, let message) = AppleFoundationModelErrors.map(error) else {
                Issue.record("Expected a normalized PCC error")
                continue
            }
            #expect(code == expectedCode)
            #expect(!message.contains("private fixture content"))
        }
    }

    @Test(.enabled(if: supportsPCCRuntime))
    func newCommonContextErrorIsMappedAlongsideLegacyGenerationErrors() {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let error = LanguageModelError.contextSizeExceeded(.init(
            contextSize: 32_768, tokenCount: 32_769, debugDescription: "private fixture content"
        ))
        #expect(AppleFoundationModelErrors.map(error) == .providerError(
            code: "context_window_exceeded", message: "Conversation exceeds the Apple model's context window."
        ))
    }

    @Test
    func unsupportedOSStillHasAPCCIdentityAndNeverGenerates() async throws {
        guard #unavailable(iOS 27.0, macOS 27.0) else { return }
        let provider = await AppleFoundationLLMProvider.make(
            id: "saved-cloud-row", model: .privateCloudCompute,
            statusProvider: FixedAppleFoundationModelStatusProvider(
                localAvailability: .available, supportsPrivateCloudCompute: true,
                privateCloudComputeStatus: Self.ready
            )
        )
        #expect(provider.id == "saved-cloud-row")
        #expect(provider.supportedModels[0].id == "private-cloud-compute")
        #expect(errorCode(in: try await run(provider)) == "pcc_requires_os_27")
    }

    private func makeProvider(
        session: MockLanguageSession.Outcome,
        initial: AppleFoundationModelStatus = Self.ready,
        status: @escaping @Sendable () async -> AppleFoundationModelStatus = { Self.ready }
    ) -> AppleFoundationLLMProvider {
        AppleFoundationLLMProvider(
            model: .privateCloudCompute, initialStatus: initial, status: status,
            sessionFactory: { _, _ in MockLanguageSession(outcome: session) },
            idGenerator: DeterministicIDGenerator(prefix: "pcc-")
        )
    }

    private func run(_ provider: AppleFoundationLLMProvider) async throws -> [LLMStreamEvent] {
        try await collect(provider.stream(
            messages: [.init(role: .user, text: "hi")], model: provider.supportedModels[0], tools: [], temperature: 0.5
        ))
    }

    private func collect(_ stream: AsyncThrowingStream<LLMStreamEvent, Error>) async throws -> [LLMStreamEvent] {
        var result: [LLMStreamEvent] = []
        for try await event in stream { result.append(event) }
        return result
    }

    private func text(in events: [LLMStreamEvent]) -> [String] {
        events.compactMap {
            if case .textDelta(_, let text) = $0 { return text }
            return nil
        }
    }

    private func errorCode(in events: [LLMStreamEvent]) -> String? {
        events.compactMap {
            if case .error(.providerError(let code, _)) = $0 { return code }
            return nil
        }.first
    }
}

/// Strict statuses advance only when the provider explicitly refreshes them.
private actor ScriptedAppleStatus {
    private var states: [AppleFoundationModelStatus]

    init(_ states: [AppleFoundationModelStatus]) { self.states = states }

    func next() -> AppleFoundationModelStatus {
        precondition(!states.isEmpty, "Unexpected status refresh")
        return states.removeFirst()
    }
}

/// Content-free stand-in for a backend error normalized through the injected seam.
private enum ScriptedError: Error { case failure }

/// New SDK error values must only be constructed on a runtime that provides them.
private var supportsPCCRuntime: Bool {
    if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) { return true }
    return false
}
