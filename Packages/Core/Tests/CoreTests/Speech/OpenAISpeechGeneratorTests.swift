import Foundation
import Testing
@testable import Core

/// Validates speech requests, safe failure translation, and strict company identification without network access.
@Suite("OpenAI speech")
struct OpenAISpeechGeneratorTests {
    @Test func requestPreservesTextAndFixesDestination() async throws {
        let http = SpeechHTTP { request in
            #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/speech")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            let json = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            #expect(json?["model"] as? String == OpenAISpeechGenerator.model)
            #expect(json?["input"] as? String == "In the beginning…")
            #expect(json?["voice"] as? String == "marin")
            #expect(json?["response_format"] as? String == "mp3")
            return AsyncThrowingStream { $0.yield(Data([1, 2])); $0.yield(Data([3])); $0.finish() }
        }
        let data = try await OpenAISpeechGenerator(http: http).generate(text: "In the beginning…", voice: .marin, apiKey: " test-key ")
        #expect(data == Data([1, 2, 3]))
    }

    @Test(arguments: [401, 403, 429, 500])
    func errorsDoNotExposeProviderBodies(status: Int) async {
        let expected: SpeechGenerationError = switch status {
        case 401: .authenticationFailed
        case 403: .permissionDenied
        case 429: .quotaExceeded
        default: .unavailable
        }
        let http = SpeechHTTP { _ in AsyncThrowingStream { $0.finish(throwing: HTTPError.badStatus(status, body: "private provider body")) } }
        await #expect(throws: expected) {
            try await OpenAISpeechGenerator(http: http).generate(text: "Hello", voice: .cedar, apiKey: "test-key")
        }
    }

    @Test(arguments: [
        (#"{"error":{"code":"invalid_api_key","message":"Incorrect API key: private-key"}}"#, SpeechGenerationError.invalidKey),
        (#"{"error":{"code":"insufficient_permissions","message":"private provider details"}}"#, .permissionDenied),
        (#"{"error":{"code":null,"message":"You have insufficient permissions for this operation. Missing scopes: api.audio.speech"}}"#, .permissionDenied),
        (#"{"error":{"code":"unknown_code","message":"private provider details"}}"#, .authenticationFailed),
        (#"{"error":{"code":null,"message":"Incorrect API key provided: private-key"}}"#, .authenticationFailed),
        ("not JSON: private-key", .authenticationFailed),
    ])
    func authenticationErrorsUseProviderReason(body: String, expected: SpeechGenerationError) async {
        let http = SpeechHTTP { _ in
            AsyncThrowingStream { $0.finish(throwing: HTTPError.badStatus(401, body: body)) }
        }
        await #expect(throws: expected) {
            try await OpenAISpeechGenerator(http: http).generate(text: "Hello", voice: .marin, apiKey: "test-key")
        }
        #expect(!expected.message.contains("private"))
        #expect(!String(describing: expected).contains("private"))
    }

    @Test func invalidInputsNeverStartNetwork() async {
        let generator = OpenAISpeechGenerator(http: SpeechHTTP { _ in fatalError("Unexpected request") })
        await #expect(throws: SpeechGenerationError.missingKey) {
            try await generator.generate(text: "Hello", voice: .marin, apiKey: " ")
        }
        await #expect(throws: SpeechGenerationError.inputTooLong) {
            try await generator.generate(text: String(repeating: "x", count: 1601), voice: .marin, apiKey: "key")
        }
    }

    @Test func emptyAudioRejected() async {
        let generator = OpenAISpeechGenerator(http: SpeechHTTP { _ in AsyncThrowingStream { $0.finish() } })
        await #expect(throws: SpeechGenerationError.invalidAudio) {
            try await generator.generate(text: "Hello", voice: .marin, apiKey: "key")
        }
    }

    @Test func compatibleServersAreNotOpenAI() {
        for url in ["http://api.openai.com/v1", "https://proxy.test/v1", "https://api.openai.com/v1?key=x", "https://api.openai.com:8443/v1", "https://user@api.openai.com/v1"] {
            #expect(!ProviderAudioCredential.isDirectOpenAI(providerId: "openai", baseURL: URL(string: url)))
        }
        #expect(!ProviderAudioCredential.isDirectOpenAI(providerId: "custom", baseURL: URL(string: "https://api.openai.com/v1")))
        #expect(!ProviderAudioCredential.isDirectOpenAI(providerId: nil, baseURL: URL(string: "https://api.openai.com/v1")))
        #expect(ProviderAudioCredential.isDirectOpenAI(providerId: "openai", baseURL: URL(string: "https://api.openai.com/v1/")))
    }
}

private struct SpeechHTTP: HTTPClient {
    let response: @Sendable (URLRequest) -> AsyncThrowingStream<Data, Error>
    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> { response(request) }
}
