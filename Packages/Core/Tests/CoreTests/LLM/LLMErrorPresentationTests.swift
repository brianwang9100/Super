import Foundation
import Testing
@testable import Core

@Suite("LLM error presentation")
struct LLMErrorPresentationTests {
    @Test("localized provider failures retain the code and actionable detail")
    func localizedProviderDetails() {
        let error: any Error = LLMError.providerError(
            code: "400",
            message: "HTTP 400: Unsupported temperature: only the default value is supported."
        )

        #expect(error.localizedDescription.contains("HTTP 400"))
        #expect(error.localizedDescription.contains("Unsupported temperature"))
        #expect(error.localizedDescription.contains("only the default value is supported"))
    }

    @Test("non-HTTP provider codes remain identifiable without an HTTP label", arguments: [
        "context_window_exceeded", "409",
    ])
    func localizedNonHTTPProviderCode(_ code: String) {
        let error: any Error = LLMError.providerError(
            code: code, message: "Start a shorter conversation."
        )

        #expect(error.localizedDescription.contains(code))
        #expect(error.localizedDescription.contains("Start a shorter conversation."))
        #expect(!error.localizedDescription.contains("HTTP"))
    }

    @Test("localized interruption and request details remain actionable", arguments: [
        LLMError.requestFailed("The stream ended before completion. Try again."),
        LLMError.decodingFailed("The provider returned an incomplete response."),
    ])
    func localizedFailureDetails(_ error: LLMError) {
        switch error {
        case .requestFailed(let message), .decodingFailed(let message):
            #expect(error.localizedDescription == message)
        default:
            Issue.record("Expected a request or decoding failure")
        }
    }
}
