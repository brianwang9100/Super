import FoundationModels

/// Normalized availability of the on-device Apple Foundation Model (AFM)
/// exposed by `FoundationModels.SystemLanguageModel`. Wraps Apple's
/// nested `Availability` / `UnavailableReason` pair in our own type so
/// callers can `switch` on a single value without importing
/// `FoundationModels`.
///
/// The Chat Settings pane renders one row per state; the
/// `AppleFoundationLLMProvider` rejects `stream(...)` calls whenever
/// availability is anything but `.available`.
public enum AppleFoundationAvailability: Sendable, Equatable {
    case available
    case unavailable(Reason)

    /// Why AFM cannot serve a turn right now. Maps 1:1 onto Apple's
    /// `SystemLanguageModel.Availability.UnavailableReason`, plus a
    /// catch-all for forward-compatible new cases.
    public enum Reason: Sendable, Equatable, CaseIterable {
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
    }

    /// Map Apple's `SystemLanguageModel.Availability` into our flat shape.
    ///
    /// The outer switch does not carry `@unknown default`: Apple marks
    /// `Availability` itself as `@frozen`, so `available` / `unavailable`
    /// are the entire case set and the compiler emits a "default will
    /// never be executed" warning if one is added. The inner
    /// `UnavailableReason` switch is not frozen, so a future Apple SDK
    /// could ship a new reason — those land as `.modelNotReady` (the
    /// most user-actionable default — "we're working on it") rather
    /// than crashing.
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
    /// Stable identifier surfaced via `LLMError.providerError(code:...)` so
    /// the Chat UI can render a specific banner per reason without
    /// pattern-matching localized strings.
    public var errorCode: String {
        switch self {
        case .deviceNotEligible: return "afm_device_not_eligible"
        case .appleIntelligenceNotEnabled: return "afm_apple_intelligence_not_enabled"
        case .modelNotReady: return "afm_model_not_ready"
        }
    }

    /// User-facing default message. The Chat UI may override per code.
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
}
