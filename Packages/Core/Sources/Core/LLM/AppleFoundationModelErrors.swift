import FoundationModels

/// Normalizes newer Apple model errors without leaking SDK-specific types or
/// debug descriptions (which may contain request content) into application state.
enum AppleFoundationModelErrors {
    static func map(_ error: any Error) -> LLMError? {
        if let error = error as? LLMError { return error }
        if error is CancellationError { return .cancelled }
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) {
            if let error = error as? PrivateCloudComputeLanguageModel.Error {
                return mapPrivateCloudCompute(error)
            }
            if let error = error as? LanguageModelError {
                return mapLanguageModel(error)
            }
        }
        return nil
    }

    @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
    private static func mapPrivateCloudCompute(_ error: PrivateCloudComputeLanguageModel.Error) -> LLMError {
        switch error {
        case .quotaLimitReached:
            .providerError(
                code: "pcc_quota_limit_reached",
                message: "Private Cloud Compute's daily usage limit has been reached. Wait for it to reset or choose another model."
            )
        case .networkFailure:
            .providerError(
                code: "pcc_network_failure",
                message: "Private Cloud Compute could not be reached. Check your connection and try again, or choose another model."
            )
        case .serviceUnavailable:
            .providerError(
                code: "pcc_service_unavailable",
                message: "Private Cloud Compute is temporarily unavailable. Try again later or choose another model."
            )
        @unknown default:
            .providerError(code: "pcc_request_failed", message: "Private Cloud Compute could not complete this request.")
        }
    }

    @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
    private static func mapLanguageModel(_ error: LanguageModelError) -> LLMError {
        switch error {
        case .contextSizeExceeded:
            .providerError(code: "context_window_exceeded", message: "Conversation exceeds the Apple model's context window.")
        case .rateLimited:
            .rateLimited
        case .refusal:
            .providerError(code: "refusal", message: "The Apple model refused to respond.")
        case .timeout:
            .providerError(code: "apple_model_timeout", message: "The Apple model request timed out. Try again.")
        case .guardrailViolation:
            .providerError(code: "guardrail_violation", message: "The Apple model declined to respond to this prompt.")
        case .unsupportedCapability:
            .providerError(code: "unsupported_capability", message: "The Apple model does not support this feature.")
        case .unsupportedTranscriptContent:
            .providerError(code: "unsupported_transcript_content", message: "The Apple model cannot process this conversation content.")
        case .unsupportedGenerationGuide:
            .providerError(code: "unsupported_guide", message: "Generation guide is not supported by the Apple model.")
        case .unsupportedLanguageOrLocale:
            .providerError(code: "unsupported_locale", message: "Apple Intelligence does not support this device's language or locale.")
        @unknown default:
            .providerError(code: "unknown_generation_error", message: "The Apple model could not complete this request.")
        }
    }
}
