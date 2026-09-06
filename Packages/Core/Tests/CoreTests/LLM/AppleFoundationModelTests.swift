import Foundation
import Testing
@testable import Core

/// Verifies app-owned Apple identities, OS-independent status, and metadata caching.
@Suite
struct AppleFoundationModelTests {
    @Test
    func identitiesKeepLegacyLocalDiscriminator() {
        #expect(AppleFoundationModel.local.rawValue == AppleFoundationLLMProvider.defaultModelID)
        #expect(AppleFoundationModel.privateCloudCompute.rawValue == "private-cloud-compute")
        #expect(AppleFoundationModel(rawValue: "unknown") == nil)
        #expect(AppleFoundationModel.allCases.count == 2)
    }

    @Test
    func fixedOS26StatusPreservesLocalReadinessAndRejectsPCC() async {
        let source = FixedAppleFoundationModelStatusProvider(
            localAvailability: .unavailable(.appleIntelligenceNotEnabled), localContextTokens: 8_192
        )
        let local = await source.status(for: .local)
        let cloud = await source.status(for: .privateCloudCompute)
        #expect(!source.supportsPrivateCloudCompute)
        #expect(local.availability == .unavailable(.local(.appleIntelligenceNotEnabled)))
        #expect(local.contextTokens == 8_192)
        #expect(cloud.availability == .unavailable(.requiresNewerOS))
        #expect(cloud.contextTokens == nil)
    }

    @Test
    func PCCReadinessIsNotGatedByTheLocalModel() async {
        let cloud = AppleFoundationModelStatus(
            model: .privateCloudCompute, availability: .available, contextTokens: 32_768
        )
        let source = FixedAppleFoundationModelStatusProvider(
            localAvailability: .unavailable(.modelNotReady),
            supportsPrivateCloudCompute: true, privateCloudComputeStatus: cloud
        )
        #expect(await source.status(for: .privateCloudCompute) == cloud)
        #expect((await source.status(for: .local)).canGenerate == false)
        #expect(cloud.canGenerate)
    }

    @Test
    func OS27SupportDoesNotInventServiceReadiness() async {
        let source = FixedAppleFoundationModelStatusProvider(
            localAvailability: .available, supportsPrivateCloudCompute: true
        )
        #expect(source.supportsPrivateCloudCompute)
        let status = await source.status(for: .privateCloudCompute)
        #expect(status.availability == .unavailable(.systemNotReady))
        #expect(status.contextTokens == nil)
        #expect(!status.canGenerate)
    }

    @Test
    func quotaCanBlockAnAvailableModelAndKeepsResetDate() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let status = AppleFoundationModelStatus(
            model: .privateCloudCompute, availability: .available, contextTokens: 32_768,
            quota: .init(state: .limitReached, resetDate: reset)
        )
        #expect(status.availability.isAvailable)
        #expect(status.quota?.isLimitReached == true)
        #expect(status.quota?.resetDate == reset)
        #expect(!status.canGenerate)
        #expect(code(of: status.blockingError) == "pcc_quota_limit_reached")
    }

    @Test
    func approachingQuotaDoesNotBlockGeneration() {
        let status = AppleFoundationModelStatus(
            model: .privateCloudCompute, availability: .available, contextTokens: 32_768,
            quota: .init(state: .approachingLimit)
        )
        #expect(status.quota?.isApproachingLimit == true)
        #expect(status.canGenerate)
    }

    @Test(arguments: [nil, 0, -1] as [Int?])
    func unresolvedOrInvalidContextCannotEnableGeneration(tokens: Int?) {
        let status = AppleFoundationModelStatus(
            model: .privateCloudCompute, availability: .available, contextTokens: tokens
        )
        #expect(!status.canGenerate)
        #expect(code(of: status.blockingError) == "apple_model_metadata_unavailable")
    }

    @Test
    func metadataFailureIsSeparateFromServiceReadiness() {
        let failure = LLMError.providerError(code: "pcc_network_failure", message: "fixture")
        let status = AppleFoundationModelStatus(
            model: .privateCloudCompute, availability: .available, metadataError: failure
        )
        #expect(status.availability.isAvailable)
        #expect(status.blockingError == failure)
        #expect(status.contextTokens == nil)
    }

    @Test
    func successfulContextIsCachedForAllSubsequentReaders() async {
        let query = ScriptedContextQuery([.success(32_768)])
        let source = AppleFoundationContextProvider { await query.next() }
        async let first = source.resolve()
        async let second = source.resolve()
        let results = await [first, second]
        #expect(results == [.success(32_768), .success(32_768)])
        #expect(await source.resolve() == .success(32_768))
        #expect(await query.callCount == 1)
    }

    @Test
    func failedContextQueryCanBeRetried() async {
        let query = ScriptedContextQuery([.failure(.rateLimited), .success(16_384)])
        let source = AppleFoundationContextProvider { await query.next() }
        #expect(await source.resolve() == .failure(.rateLimited))
        #expect(await source.resolve() == .success(16_384))
        #expect(await source.resolve() == .success(16_384))
        #expect(await query.callCount == 2)
    }

    @Test
    func invalidContextIsNeitherCachedNorTreatedAsUsable() async {
        let query = ScriptedContextQuery([.success(0), .success(8_192)])
        let source = AppleFoundationContextProvider { await query.next() }
        guard case .failure(let error) = await source.resolve() else {
            Issue.record("Expected invalid context to fail")
            return
        }
        #expect(code(of: error) == "apple_model_metadata_unavailable")
        #expect(await source.resolve() == .success(8_192))
        #expect(await query.callCount == 2)
    }

    private func code(of error: LLMError?) -> String? {
        if case .providerError(let code, _) = error { return code }
        return nil
    }
}

/// Strict deterministic metadata script; exhausted requests identify a fixture bug.
private actor ScriptedContextQuery {
    private var outcomes: [Result<Int, LLMError>]
    private(set) var callCount = 0

    init(_ outcomes: [Result<Int, LLMError>]) { self.outcomes = outcomes }

    func next() -> Result<Int, LLMError> {
        precondition(!outcomes.isEmpty, "Unexpected context metadata query")
        callCount += 1
        return outcomes.removeFirst()
    }
}
