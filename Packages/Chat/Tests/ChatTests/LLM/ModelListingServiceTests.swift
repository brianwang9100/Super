import Core
import Foundation
import Testing
@testable import Chat

/// Tests for `LiveModelListingService` — the live `GET …/models` call that
/// feeds the Add-Model "Model" dropdown. Exercises all three wire formats
/// (OpenAI-compatible `data[]`, Anthropic-native `data[]` with its distinct
/// URL/headers, and Gemini `models[]`), the request shape (URL, method, auth
/// header per kind), and the error mapping. No real network — every case
/// replays a canned body or error through `FakeHTTPClient`.
@Suite("LiveModelListingService")
struct ModelListingServiceTests {
    private func service(_ http: HTTPClient) -> LiveModelListingService {
        LiveModelListingService(http: http)
    }

    private func body(_ json: String) -> FakeHTTPClient {
        FakeHTTPClient(chunks: [Data(json.utf8)])
    }

    // MARK: - OpenAI-compatible wire format

    @Test("OpenAI-compatible: parses data[].id and issues GET …/models with Bearer auth")
    func openAICompatibleParsesAndAuthenticates() async throws {
        let http = body(#"{"data":[{"id":"gpt-5.5"},{"id":"gpt-5.4-mini"}]}"#)
        let ids = try await service(http).listModelIDs(
            kind: .openAICompatible,
            baseURL: URL(string: "https://api.openai.com/v1")!,
            apiKey: "sk-test"
        )
        #expect(ids == ["gpt-5.5", "gpt-5.4-mini"])

        let request = try #require(http.observed.all.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    // MARK: - Anthropic native listing (regression: the /v1/openai/ shim has no /models)

    @Test("Anthropic: the /v1/openai/ shim base rewrites to native /v1/models with x-api-key + anthropic-version")
    func anthropicShimBaseRewritesToNativeModelsEndpoint() async throws {
        // Regression for the Add-Model live fetch 404ing on Anthropic: the
        // chat shim base has no /models endpoint, and the native endpoint
        // rejects Bearer auth. Verified by curl 2026-06-11 — only
        // `GET /v1/models` + `x-api-key` + `anthropic-version` succeeds.
        let http = body(#"{"data":[{"id":"claude-opus-4-7"},{"id":"claude-sonnet-4-6"}]}"#)
        let ids = try await service(http).listModelIDs(
            kind: .openAICompatible,
            baseURL: URL(string: "https://api.anthropic.com/v1/openai/")!,
            apiKey: "sk-ant"
        )
        #expect(ids == ["claude-opus-4-7", "claude-sonnet-4-6"])

        let request = try #require(http.observed.all.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1000")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        // The native endpoint 401s on Bearer — it must not be attached.
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Anthropic: an .anthropicNative row lists via the native /v1/models with x-api-key")
    func anthropicNativeKindUsesNativeModelsEndpoint() async throws {
        // Regression for the PR2 native flip: the default Anthropic preset is
        // now `.anthropicNative`. Listing must still hit the native endpoint
        // (kind alone is enough — no host check needed), not throw
        // `.unsupportedKind` and silently fall back to the static catalog.
        let http = body(#"{"data":[{"id":"claude-opus-4-7"}]}"#)
        let ids = try await service(http).listModelIDs(
            kind: .anthropicNative,
            baseURL: URL(string: "https://api.anthropic.com/v1")!,
            apiKey: "sk-ant"
        )
        #expect(ids == ["claude-opus-4-7"])

        let request = try #require(http.observed.all.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1000")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Anthropic: a bare /v1 base also yields /v1/models (no /openai segment to strip)")
    func anthropicBareV1BaseYieldsNativeModelsEndpoint() async throws {
        let http = body(#"{"data":[{"id":"claude-haiku-4-5-20251001"}]}"#)
        _ = try await service(http).listModelIDs(
            kind: .openAICompatible,
            baseURL: URL(string: "https://api.anthropic.com/v1")!,
            apiKey: "sk-ant"
        )
        let request = try #require(http.observed.all.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1000")
    }

    @Test("Anthropic: a bare-host base (user-edited, no path) heals to /v1/models")
    func anthropicBareHostBaseHealsToV1Models() async throws {
        // The /v1 default exists for user-edited bases: without it a bare
        // host would yield the nonexistent host-root /models.
        let http = body(#"{"data":[{"id":"claude-opus-4-7"}]}"#)
        _ = try await service(http).listModelIDs(
            kind: .openAICompatible,
            baseURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "sk-ant"
        )
        let request = try #require(http.observed.all.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1000")
    }

    @Test("OpenAI-compatible: a trailing-slash base joins to /models without a double slash")
    func openAICompatibleTrailingSlashBaseJoins() async throws {
        // Pins the generic path's slash canonicalization — previously only
        // covered via the (since-rerouted) Anthropic shim base.
        let http = body(#"{"data":[{"id":"local-model"}]}"#)
        _ = try await service(http).listModelIDs(
            kind: .openAICompatible,
            baseURL: URL(string: "http://127.0.0.1:11434/v1/")!,
            apiKey: nil
        )
        let request = try #require(http.observed.all.first)
        #expect(request.url?.absoluteString == "http://127.0.0.1:11434/v1/models")
    }

    @Test("isAnthropicHost gates on the first-party host only — proxies stay OpenAI-compatible")
    func isAnthropicHostTable() {
        #expect(LiveModelListingService.isAnthropicHost(URL(string: "https://api.anthropic.com/v1/openai/")!))
        #expect(LiveModelListingService.isAnthropicHost(URL(string: "https://API.ANTHROPIC.COM/v1")!))
        #expect(!LiveModelListingService.isAnthropicHost(URL(string: "https://api.openai.com/v1")!))
        #expect(!LiveModelListingService.isAnthropicHost(URL(string: "https://my-claude-proxy.example.com/v1")!))
    }

    @Test("No key: no Authorization header is attached (local/unauthenticated endpoints)")
    func openAICompatibleNoKeyOmitsAuth() async throws {
        let http = body(#"{"data":[{"id":"local-model"}]}"#)
        _ = try await service(http).listModelIDs(
            kind: .openAICompatible,
            baseURL: URL(string: "http://127.0.0.1:1111/v1")!,
            apiKey: nil
        )
        let request = try #require(http.observed.all.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - Chat-only filtering (OpenAI-compatible)

    @Test("OpenAI-compatible: non-chat models (speech, image, embedding, moderation) are filtered out")
    func openAICompatibleFiltersNonChatModels() async throws {
        let http = body(
            #"{"data":[{"id":"gpt-5.5"},{"id":"whisper-1"},{"id":"text-embedding-3-large"},"# +
                #"{"id":"dall-e-3"},{"id":"gpt-4o-mini-tts"},{"id":"omni-moderation-latest"},"# +
                #"{"id":"gpt-realtime"},{"id":"gpt-image-1"},{"id":"sora-2"},{"id":"gpt-4o-transcribe"}]}"#
        )
        let ids = try await service(http).listModelIDs(
            kind: .openAICompatible,
            baseURL: URL(string: "https://api.openai.com/v1")!,
            apiKey: "sk-test"
        )
        #expect(ids == ["gpt-5.5"])
    }

    @Test("xAI-shaped body: chat Grok models survive, image-generation ids drop")
    func xaiFiltersImageModels() async throws {
        let http = body(#"{"data":[{"id":"grok-4.3"},{"id":"grok-2-image-1212"},{"id":"grok-imagine-1"}]}"#)
        let ids = try await service(http).listModelIDs(
            kind: .openAICompatible,
            baseURL: URL(string: "https://api.x.ai/v1")!,
            apiKey: "xai-test"
        )
        #expect(ids == ["grok-4.3"])
    }

    @Test("isLikelyChatModelID keeps chat ids — including unknown future ones — and drops non-chat modalities")
    func isLikelyChatModelIDTable() {
        let kept = ["gpt-5.5", "claude-opus-4-7", "grok-4.3", "gemini-3-pro", "some-future-chat-model"]
        for id in kept {
            #expect(LiveModelListingService.isLikelyChatModelID(id), "expected to keep \(id)")
        }
        let dropped = [
            "whisper-1", "gpt-4o-mini-tts", "dall-e-3", "text-embedding-3-large",
            "omni-moderation-latest", "gpt-realtime", "gpt-4o-audio-preview",
            "gpt-4o-transcribe", "gpt-image-1", "grok-imagine-1", "sora-2",
            "babbage-002", "davinci-002", "WHISPER-LARGE",
        ]
        for id in dropped {
            #expect(!LiveModelListingService.isLikelyChatModelID(id), "expected to drop \(id)")
        }
    }

    // MARK: - Chat-only filtering (Gemini)

    @Test("Gemini: models without generateContent support are filtered; a missing methods field passes")
    func geminiFiltersByGenerationMethods() async throws {
        let http = body(
            #"{"models":["# +
                #"{"name":"models/gemini-3-pro","supportedGenerationMethods":["generateContent","countTokens"]},"# +
                #"{"name":"models/text-embedding-005","supportedGenerationMethods":["embedContent"]},"# +
                #"{"name":"models/imagen-4","supportedGenerationMethods":["predict"]},"# +
                #"{"name":"models/veo-3","supportedGenerationMethods":["predictLongRunning"]},"# +
                #"{"name":"models/gemini-proxy-no-methods"}"# +
            #"]}"#
        )
        let ids = try await service(http).listModelIDs(
            kind: .geminiNative,
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
            apiKey: "g-key"
        )
        #expect(ids == ["gemini-3-pro", "gemini-proxy-no-methods"])
    }

    @Test("Gemini: TTS/image models that also advertise generateContent are dropped by the id heuristic")
    func geminiFiltersTTSAndImageModelsByID() async throws {
        // Gemini's speech and image-generation models respond via
        // generateContent too (audio/image response modalities), so the
        // methods check alone would pass them — the id heuristic is the
        // second gate.
        let http = body(
            #"{"models":["# +
                #"{"name":"models/gemini-3-pro","supportedGenerationMethods":["generateContent"]},"# +
                #"{"name":"models/gemini-3-flash-tts","supportedGenerationMethods":["generateContent"]},"# +
                #"{"name":"models/gemini-3-flash-image","supportedGenerationMethods":["generateContent"]}"# +
            #"]}"#
        )
        let ids = try await service(http).listModelIDs(
            kind: .geminiNative,
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
            apiKey: "g-key"
        )
        #expect(ids == ["gemini-3-pro"])
    }

    // MARK: - Gemini wire format

    @Test("Gemini: parses models[].name, strips the models/ prefix, uses x-goog-api-key")
    func geminiParsesAndStripsPrefix() async throws {
        let http = body(#"{"models":[{"name":"models/gemini-3-pro"},{"name":"models/gemini-3.5-flash"}]}"#)
        let ids = try await service(http).listModelIDs(
            kind: .geminiNative,
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
            apiKey: "g-key"
        )
        #expect(ids == ["gemini-3-pro", "gemini-3.5-flash"])

        let request = try #require(http.observed.all.first)
        #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "g-key")
        // Gemini must not carry a Bearer header.
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - Errors

    @Test("Unsupported kinds throw .unsupportedKind without issuing a request")
    func unsupportedKindThrows() async throws {
        let http = body("{}")
        await #expect(throws: ModelListingError.unsupportedKind(.appleFoundation)) {
            try await service(http).listModelIDs(
                kind: .appleFoundation,
                baseURL: URL(string: "https://example.test/v1")!,
                apiKey: nil
            )
        }
        #expect(http.observed.all.isEmpty)
    }

    @Test("A non-2xx status maps to .transport carrying the assembled body")
    func badStatusMapsToTransport() async throws {
        let http = FakeHTTPClient(error: HTTPError.badStatus(401, body: "invalid api key"))
        // Pin the exact case + message so a regression in `describe(_:)`'s
        // "HTTP <code>: <body>" assembly is caught, not just "some error".
        await #expect(throws: ModelListingError.transport("HTTP 401: invalid api key")) {
            try await service(http).listModelIDs(
                kind: .openAICompatible,
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKey: "bad"
            )
        }
    }

    @Test("An undecodable body maps to .decoding")
    func garbageBodyMapsToDecoding() async throws {
        let http = body("not json at all")
        await #expect(throws: ModelListingError.decoding) {
            try await service(http).listModelIDs(
                kind: .openAICompatible,
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKey: "sk-test"
            )
        }
    }
}
