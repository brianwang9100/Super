import FoundationModels

/// Keeps FoundationModels availability types out of callers' imports.
public enum AppleFoundationAvailability: Sendable, Equatable {
    case available
    case unavailable(Reason)

    public enum Reason: Sendable, Equatable, CaseIterable {
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
    }

    // Availability is frozen; UnavailableReason is not. Unknown reasons map to modelNotReady.
    public init(_ availability: SystemLanguageModel.Availability) {
        switch availability {
        case .available:
            self = .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                self = .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled:
                self = .unavailable(.appleIntelligenceNotEnabled)
            case .modelNotReady:
                self = .unavailable(.modelNotReady)
            @unknown default:
                self = .unavailable(.modelNotReady)
            }
        }
    }

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

extension AppleFoundationAvailability.Reason {
    /// Stable codes let UI choose recovery without parsing localized messages.
    public var errorCode: String {
        switch self {
        case .deviceNotEligible: return "afm_device_not_eligible"
        case .appleIntelligenceNotEnabled: return "afm_apple_intelligence_not_enabled"
        case .modelNotReady: return "afm_model_not_ready"
        }
    }

    public var errorMessage: String {
        switch self {
        case .deviceNotEligible:
            return "This device is not eligible for Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is not enabled in System Settings."
        case .modelNotReady:
            return "Apple Intelligence is preparing the on-device model. Try again shortly."
        }
    }

    public var subtitle: String {
        switch self {
        case .deviceNotEligible: return "Device not eligible"
        case .appleIntelligenceNotEnabled: return "Apple Intelligence off"
        case .modelNotReady: return "Model not ready"
        }
    }
}
