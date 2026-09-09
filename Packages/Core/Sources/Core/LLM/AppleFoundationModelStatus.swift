import Foundation

/// Model-specific readiness, independently tracked usage quota, and resolved
/// metadata without exposing newer framework types to iOS 26 consumers.
public struct AppleFoundationModelStatus: Sendable, Equatable {
    public let model: AppleFoundationModel
    public let availability: Availability
    public let contextTokens: Int?
    public let quota: QuotaUsage?
    public let metadataError: LLMError?

    public init(
        model: AppleFoundationModel,
        availability: Availability,
        contextTokens: Int? = nil,
        quota: QuotaUsage? = nil,
        metadataError: LLMError? = nil
    ) {
        self.model = model
        self.availability = availability
        self.contextTokens = contextTokens
        self.quota = quota
        self.metadataError = metadataError
    }

    /// Service readiness is separate from daily usage and metadata resolution.
    public enum Availability: Sendable, Equatable {
        case available
        case unavailable(Reason)

        public var isAvailable: Bool { self == .available }
    }

    /// Reasons actually exposed by the selected backend, plus OS/unknown guards.
    /// PCC's system-not-ready state must not be misrepresented as a local download.
    public enum Reason: Sendable, Equatable {
        case requiresNewerOS
        case local(AppleFoundationAvailability.Reason)
        case deviceNotEligible
        case systemNotReady
        case unknown

        public var errorCode: String {
            switch self {
            case .requiresNewerOS: "pcc_requires_os_27"
            case .local(let reason): reason.errorCode
            case .deviceNotEligible: "pcc_device_not_eligible"
            case .systemNotReady: "pcc_system_not_ready"
            case .unknown: "pcc_unavailable"
            }
        }

        public var errorMessage: String {
            switch self {
            case .requiresNewerOS:
                "Private Cloud Compute requires iOS 27 or macOS 27 or later."
            case .local(let reason): reason.errorMessage
            case .deviceNotEligible:
                "This device is not eligible for Apple Intelligence."
            case .systemNotReady:
                "Private Cloud Compute is not ready to serve requests. Try again shortly."
            case .unknown:
                "Private Cloud Compute is currently unavailable."
            }
        }

        public var subtitle: String {
            switch self {
            case .requiresNewerOS: "Requires OS 27 or later"
            case .local(let reason): reason.subtitle
            case .deviceNotEligible: "Device not eligible"
            case .systemNotReady: "Private Cloud Compute not ready"
            case .unknown: "Private Cloud Compute unavailable"
            }
        }
    }

    /// A daily budget snapshot, independent of whether the service is available.
    public struct QuotaUsage: Sendable, Equatable {
        public let state: State
        public let resetDate: Date?

        public init(state: State, resetDate: Date? = nil) {
            self.state = state
            self.resetDate = resetDate
        }

        /// Normalized quota states; no request counts are inferred from Apple's API.
        public enum State: Sendable, Equatable {
            case belowLimit
            case approachingLimit
            case limitReached
        }

        public var isLimitReached: Bool { state == .limitReached }
        public var isApproachingLimit: Bool { state == .approachingLimit }
    }

    /// A usable model needs readiness, remaining quota, and measured metadata.
    public var canGenerate: Bool { blockingError == nil }

    /// The actionable reason generation cannot begin, without changing selection.
    public var blockingError: LLMError? {
        if case .unavailable(let reason) = availability {
            return .providerError(code: reason.errorCode, message: reason.errorMessage)
        }
        if quota?.isLimitReached == true {
            return .providerError(
                code: "pcc_quota_limit_reached",
                message: "Private Cloud Compute's daily usage limit has been reached. Wait for it to reset or choose another model."
            )
        }
        if let metadataError { return metadataError }
        guard let contextTokens, contextTokens > 0 else {
            return .providerError(
                code: "apple_model_metadata_unavailable",
                message: "Apple Intelligence model information is not ready. Try again shortly."
            )
        }
        return nil
    }
}
