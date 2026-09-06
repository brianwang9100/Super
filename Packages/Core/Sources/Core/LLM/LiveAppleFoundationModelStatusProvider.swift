import FoundationModels

/// Reads live Apple model state and owns the PCC model used for both metadata
/// and generation. Only successful context metadata is cached; readiness is not.
public struct LiveAppleFoundationModelStatusProvider: AppleFoundationModelStatusProvider {
    private let privateCloudComputeStatus: (@Sendable () async -> AppleFoundationModelStatus)?
    private let privateCloudComputeSession: LanguageSessionFactory?

    public var supportsPrivateCloudCompute: Bool { privateCloudComputeStatus != nil }

    public init() {
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) {
            let model = PrivateCloudComputeLanguageModel()
            let context = AppleFoundationContextProvider {
                do {
                    return .success(try await model.contextSize)
                } catch {
                    return .failure(AppleFoundationModelErrors.map(error) ?? .providerError(
                        code: "pcc_metadata_unavailable",
                        message: "Private Cloud Compute model information could not be loaded. Try again shortly."
                    ))
                }
            }
            privateCloudComputeStatus = {
                let cachedTokens = await context.cachedContextTokens()
                let initial = Self.status(of: model)
                guard initial.availability.isAvailable, initial.quota?.isLimitReached != true else {
                    return AppleFoundationModelStatus(
                        model: .privateCloudCompute, availability: initial.availability,
                        contextTokens: cachedTokens, quota: initial.quota
                    )
                }
                let metadata = await context.resolve()
                // Read again after awaiting metadata: eligibility and quota may
                // have changed while the request was in flight.
                let refreshed = Self.status(of: model)
                switch metadata {
                case .success(let tokens):
                    return AppleFoundationModelStatus(
                        model: .privateCloudCompute, availability: refreshed.availability,
                        contextTokens: tokens, quota: refreshed.quota
                    )
                case .failure(let error):
                    return AppleFoundationModelStatus(
                        model: .privateCloudCompute, availability: refreshed.availability,
                        quota: refreshed.quota, metadataError: error
                    )
                }
            }
            privateCloudComputeSession = { transcript, tools in
                LiveLanguageSession(session: LanguageModelSession(model: model, tools: tools, transcript: transcript))
            }
        } else {
            privateCloudComputeStatus = nil
            privateCloudComputeSession = nil
        }
    }

    public func status(for model: AppleFoundationModel) async -> AppleFoundationModelStatus {
        switch model {
        case .local:
            let availability = AppleFoundationAvailability(SystemLanguageModel.default.availability)
            return await FixedAppleFoundationModelStatusProvider(
                localAvailability: availability, localContextTokens: SystemLanguageModel.default.contextSize
            ).status(for: .local)
        case .privateCloudCompute:
            guard let privateCloudComputeStatus else {
                return AppleFoundationModelStatus(model: model, availability: .unavailable(.requiresNewerOS))
            }
            return await privateCloudComputeStatus()
        }
    }

    /// The concrete facade shares one model between status and session creation.
    /// Scripted providers inject their own session factory at the adapter seam.
    func sessionFactory(for model: AppleFoundationModel) -> LanguageSessionFactory? {
        switch model {
        case .local:
            { transcript, tools in
                LiveLanguageSession(session: LanguageModelSession(
                    model: SystemLanguageModel.default, tools: tools, transcript: transcript
                ))
            }
        case .privateCloudCompute:
            privateCloudComputeSession
        }
    }

    @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
    private static func status(of model: PrivateCloudComputeLanguageModel) -> AppleFoundationModelStatus {
        let availability: AppleFoundationModelStatus.Availability
        switch model.availability {
        case .available:
            availability = .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: availability = .unavailable(.deviceNotEligible)
            case .systemNotReady: availability = .unavailable(.systemNotReady)
            @unknown default: availability = .unavailable(.unknown)
            }
        }
        let quota = model.quotaUsage
        let state: AppleFoundationModelStatus.QuotaUsage.State
        if quota.isLimitReached {
            state = .limitReached
        } else if case .belowLimit(let info) = quota.status, info.isApproachingLimit {
            state = .approachingLimit
        } else {
            state = .belowLimit
        }
        return AppleFoundationModelStatus(
            model: .privateCloudCompute,
            availability: availability,
            quota: .init(state: state, resetDate: quota.resetDate)
        )
    }
}
