/// Reads model-specific readiness and metadata without making a generation request.
/// OS capability remains independent of temporary service readiness for seeding.
public protocol AppleFoundationModelStatusProvider: Sendable {
    var supportsPrivateCloudCompute: Bool { get }
    func status(for model: AppleFoundationModel) async -> AppleFoundationModelStatus
}

/// An explicit immutable status source for previews, tests, and legacy local inputs.
/// Production flows that need refreshed readiness use the live provider instead.
public struct FixedAppleFoundationModelStatusProvider: AppleFoundationModelStatusProvider {
    public let supportsPrivateCloudCompute: Bool
    private let localAvailability: AppleFoundationAvailability
    private let privateCloudComputeStatus: AppleFoundationModelStatus?
    private let localContextTokens: Int

    public init(
        localAvailability: AppleFoundationAvailability,
        supportsPrivateCloudCompute: Bool = false,
        privateCloudComputeStatus: AppleFoundationModelStatus? = nil,
        localContextTokens: Int = AppleFoundationLLMProvider.defaultMaxContextTokens
    ) {
        self.localAvailability = localAvailability
        self.supportsPrivateCloudCompute = supportsPrivateCloudCompute
        self.privateCloudComputeStatus = privateCloudComputeStatus
        self.localContextTokens = localContextTokens
    }

    public func status(for model: AppleFoundationModel) async -> AppleFoundationModelStatus {
        switch model {
        case .local:
            let availability: AppleFoundationModelStatus.Availability
            switch localAvailability {
            case .available: availability = .available
            case .unavailable(let reason): availability = .unavailable(.local(reason))
            }
            return AppleFoundationModelStatus(
                model: .local, availability: availability, contextTokens: localContextTokens
            )
        case .privateCloudCompute:
            guard supportsPrivateCloudCompute else {
                return AppleFoundationModelStatus(model: model, availability: .unavailable(.requiresNewerOS))
            }
            guard let privateCloudComputeStatus, privateCloudComputeStatus.model == model else {
                return AppleFoundationModelStatus(model: model, availability: .unavailable(.systemNotReady))
            }
            return privateCloudComputeStatus
        }
    }
}
