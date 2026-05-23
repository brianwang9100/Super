import FoundationModels

/// Normalized availability of the on-device Apple Foundation Model (AFM)
/// exposed by `FoundationModels.SystemLanguageModel`. Collapses Apple's
/// two-level `Availability` / `UnavailableReason` enums into a single
/// flat case set so callers can `switch` once.
///
/// The Chat Settings pane renders one row per case; the
/// `AppleFoundationLLMProvider` rejects `stream(...)` calls whenever the
/// captured availability is anything but `.available`.
public enum AppleFoundationAvailability: Sendable, Equatable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady

    /// Map Apple's `SystemLanguageModel.Availability` into our flat case
    /// set. Future `UnavailableReason` cases fall back to `.modelNotReady`
    /// (the most user-actionable default — "we're working on it") rather
    /// than crashing.
    public init(_ availability: SystemLanguageModel.Availability) {
        switch availability {
        case .available:
            self = .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                self = .deviceNotEligible
            case .appleIntelligenceNotEnabled:
                self = .appleIntelligenceNotEnabled
            case .modelNotReady:
                self = .modelNotReady
            @unknown default:
                self = .modelNotReady
            }
        }
    }

    public var isAvailable: Bool {
        self == .available
    }
}
