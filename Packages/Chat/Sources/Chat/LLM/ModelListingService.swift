import Core
import Foundation

/// Errors thrown by `ModelListingService` conformers. Sendable enum defined
/// alongside the API per the typed-errors rule.
public enum ModelListingError: Error, Sendable, Equatable {
    /// The provider `kind` has no live model-list endpoint we issue against
    /// (Apple Foundation runs on-device; the Anthropic / OpenAI-Responses
    /// native-search adapter kinds aren't offered as Add-Model providers).
    case unsupportedKind(LLMProviderKind)
    /// Transport or non-2xx HTTP (HyperText Transfer Protocol) failure,
    /// carrying the underlying message.
    case transport(String)
    /// The endpoint returned a body we couldn't decode into a model list.
    case decoding
}

/// Fetches the set of model ids a provider currently exposes via its "list
/// models" endpoint. Drives the Add-Model "Model" dropdown so the picker
/// reflects what the provider actually offers rather than a hand-curated
/// snapshot. Injected as a protocol so the view model substitutes a strict
/// fake in tests.
public protocol ModelListingService: Sendable {
    /// List the wire-level **chat-capable** model ids available at `baseURL`
    /// for a provider of the given `kind`, authenticating with `apiKey` when
    /// present. Non-chat models (image, audio, embedding, moderation, …) are
    /// filtered out — the result feeds the Add-Model picker, which only
    /// configures text-chat models.
    ///
    /// - Throws: `ModelListingError` on an unsupported kind, transport /
    ///   non-2xx failure, or an undecodable body.
    func listModelIDs(kind: LLMProviderKind, baseURL: URL, apiKey: String?) async throws -> [String]
}

/// Production `ModelListingService` issuing a `GET …/models` against the
/// provider endpoint over the shared streaming `HTTPClient` (the body is
/// small JSON, so we drain the stream into one `Data` and decode it).
///
/// Three wire formats, dispatched by `kind` (plus a host check for Anthropic):
/// - `.openAICompatible` (OpenAI, xAI): `Authorization: Bearer`, response
///   `{ data: [{ id }] }`.
/// - Anthropic (any `.anthropicNative` row, or an `.openAICompatible` row whose
///   host is `api.anthropic.com`): listing uses the native
///   `GET /v1/models?limit=1000` with `x-api-key` + `anthropic-version` headers
///   (Bearer 401s there — verified by curl 2026-06-11). The default Anthropic
///   preset is `.anthropicNative`; the legacy `/v1/openai/` chat shim has **no**
///   `/models` endpoint, so a custom compat row is rewritten to the native call
///   by host. The response envelope happens to match OpenAI's
///   `{ data: [{ id }] }`, so decoding is shared.
/// - `.geminiNative` (Google): `x-goog-api-key`, response
///   `{ models: [{ name: "models/…" }] }` — the `models/` prefix is stripped
///   to the trailing wire id used everywhere else.
///
/// Every other kind throws `.unsupportedKind`: Apple Foundation has no
/// endpoint, and the native-search adapter kinds aren't built-in Add-Model
/// providers.
public struct LiveModelListingService: ModelListingService {
    private let http: HTTPClient

    public init(http: HTTPClient) {
        self.http = http
    }

    /// Internal wire-format discriminator so kind is validated exactly once.
    private enum WireFormat {
        case openAICompatible
        case anthropic
        case gemini
    }

    public func listModelIDs(kind: LLMProviderKind, baseURL: URL, apiKey: String?) async throws -> [String] {
        let format: WireFormat
        switch kind {
        case .anthropicNative:
            // The default Anthropic preset is now `.anthropicNative` (every
            // turn rides the native Messages API for prompt caching). Listing
            // always uses the native `GET /v1/models` with `x-api-key`.
            format = .anthropic
        case .openAICompatible:
            // A custom Anthropic row may still be `.openAICompatible` (e.g. the
            // `/v1/openai/` chat shim, which has no `/models` endpoint, or a
            // proxy). Host check rewrites those to the native listing too;
            // everyone else (OpenAI, xAI, …) uses the OpenAI-compatible format.
            format = Self.isAnthropicHost(baseURL) ? .anthropic : .openAICompatible
        case .geminiNative:
            format = .gemini
        case .appleFoundation, .openAIResponses:
            throw ModelListingError.unsupportedKind(kind)
        #if DEBUG
        case .debug:
            throw ModelListingError.unsupportedKind(kind)
        #endif
        }

        let url: URL
        switch format {
        case .anthropic:
            url = Self.anthropicModelsURL(baseURL: baseURL)
        case .openAICompatible, .gemini:
            url = Self.modelsURL(baseURL: baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Exhaustive switch (not `if case`) so adding a wire format forces a
        // decision about its non-auth headers here.
        switch format {
        case .anthropic:
            request.setValue(
                AnthropicNativeLLMProvider.anthropicVersion,
                forHTTPHeaderField: "anthropic-version"
            )
        case .openAICompatible, .gemini:
            break
        }
        // Same cleartext gate as the completions path: never attach a
        // credential over a non-loopback `http://` endpoint, regardless of
        // header name. See `URLSecurity.swift`.
        if let apiKey, !apiKey.isEmpty, isCleartextSafeForCredentials(url) {
            switch format {
            case .openAICompatible:
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            case .anthropic:
                request.setValue(apiKey, forHTTPHeaderField: AnthropicNativeLLMProvider.apiKeyHeaderField)
            case .gemini:
                request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            }
        }

        let data = try await drain(request)

        switch format {
        case .openAICompatible, .anthropic:
            guard let decoded = try? JSONDecoder().decode(OpenAIModelsResponse.self, from: data) else {
                throw ModelListingError.decoding
            }
            return decoded.data.map(\.id).filter(Self.isLikelyChatModelID)
        case .gemini:
            guard let decoded = try? JSONDecoder().decode(GeminiModelsResponse.self, from: data) else {
                throw ModelListingError.decoding
            }
            return decoded.models
                .filter { Self.isChatCapableGemini(methods: $0.supportedGenerationMethods) }
                .map { Self.strippedGeminiName($0.name) }
                .filter(Self.isLikelyChatModelID)
        }
    }

    /// Drain the streaming HTTP response into one buffer. Non-2xx surfaces as
    /// `HTTPError.badStatus` from the client, which we remap to `.transport`
    /// so callers see a single `ModelListingError` type.
    private func drain(_ request: URLRequest) async throws -> Data {
        var buffer = Data()
        do {
            for try await chunk in http.stream(request) {
                buffer.append(chunk)
            }
        } catch let error as HTTPError {
            throw ModelListingError.transport(Self.describe(error))
        } catch {
            throw ModelListingError.transport(error.localizedDescription)
        }
        return buffer
    }

    private static func describe(_ error: HTTPError) -> String {
        switch error {
        case let .badStatus(code, body):
            return body.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(body)"
        case .invalidResponse:
            return "invalid response"
        case let .transport(message):
            return message
        }
    }

    /// Append `/models` to the provider base, trailing-slash tolerant — the
    /// same canonicalization the completions path applies for
    /// `/chat/completions`. So `…/v1` and `…/v1/` both yield `…/v1/models`.
    /// (Anthropic-host bases never reach this builder — `listModelIDs`
    /// routes them to `anthropicModelsURL` instead.)
    static func modelsURL(baseURL: URL) -> URL {
        joinedModelsURL(baseURL: baseURL, stripSuffix: nil, emptyPathDefault: nil, queryItems: nil)
    }

    /// Whether `url` points at Anthropic's first-party API host (the one host
    /// where the OpenAI-compat shim serves chat but not `/models`). Compared
    /// against `LLMProviderCatalog.anthropicNativeBaseURL` so the literal
    /// lives in exactly one place (an invariant test pins the anthropic
    /// entry's shim `defaultBaseURL` to this same host). A custom provider on
    /// any other host — including an Anthropic-compatible proxy — keeps the
    /// plain OpenAI-compatible listing path.
    static func isAnthropicHost(_ url: URL) -> Bool {
        url.host()?.lowercased() == Self.anthropicHost
    }

    /// Lowercased host of the Anthropic native base, parsed once — the
    /// constant can't change at runtime, so per-call re-parsing is waste.
    private static let anthropicHost = LLMProviderCatalog.anthropicNativeBaseURL.host()?.lowercased()

    /// Rewrite an Anthropic base URL to the native models-listing endpoint:
    /// strip a trailing `/openai` shim segment, append `/models`, and request
    /// the maximum page size (the endpoint paginates at 20 by default; 1000
    /// is its documented cap and comfortably covers the catalog, so `has_more`
    /// is intentionally not walked). `…/v1/openai/`, `…/v1/openai`, `…/v1/`,
    /// and `…/v1` all yield `…/v1/models?limit=1000`; a bare host (path-less
    /// user-edited base) is healed to `/v1/models` rather than the
    /// nonexistent host-root `/models`.
    static func anthropicModelsURL(baseURL: URL) -> URL {
        joinedModelsURL(
            baseURL: baseURL,
            stripSuffix: "/openai",
            emptyPathDefault: "/v1",
            queryItems: [URLQueryItem(name: "limit", value: "1000")]
        )
    }

    /// Single canonicalization core behind `modelsURL` and
    /// `anthropicModelsURL` so trailing-slash/suffix handling can't drift
    /// between wire formats: strip trailing slashes, optionally strip a
    /// provider-shim suffix, heal an empty path to `emptyPathDefault`, append
    /// `/models`, and attach `queryItems` when given (replacing the base's —
    /// no catalog base carries a query).
    private static func joinedModelsURL(
        baseURL: URL,
        stripSuffix: String?,
        emptyPathDefault: String?,
        queryItems: [URLQueryItem]?
    ) -> URL {
        let suffix = "/models"
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL.appending(path: "models")
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if let stripSuffix, path.hasSuffix(stripSuffix) { path.removeLast(stripSuffix.count) }
        if path.isEmpty, let emptyPathDefault { path = emptyPathDefault }
        if !path.hasSuffix(suffix) { path += suffix }
        components.path = path
        if let queryItems { components.queryItems = queryItems }
        return components.url ?? baseURL.appending(path: "models")
    }

    /// Id substrings that mark a model as non-chat (speech, image,
    /// embedding, moderation, legacy completions). Hoisted so the filter
    /// pass doesn't rebuild the array once per model id.
    private static let nonChatMarkers = [
        "whisper", "tts", "dall-e", "embedding", "moderation",
        "realtime", "audio", "transcribe", "image", "imagine",
        "sora", "babbage", "davinci",
    ]

    /// Heuristic chat-model gate for ids with no (or incomplete) modality
    /// metadata. Case-insensitive substring **exclusion** — unknown ids
    /// pass, so a future chat model is never hidden by default; only ids
    /// that advertise a non-chat modality drop out. xAI's
    /// `/v1/language-models` endpoint returns authoritative modalities,
    /// but using it would special-case one provider out of the kind-keyed
    /// wire-format dispatch above — consciously rejected in favor of this
    /// shared heuristic (xAI's non-chat ids all contain "image"/"imagine").
    static func isLikelyChatModelID(_ id: String) -> Bool {
        let lowered = id.lowercased()
        return !Self.nonChatMarkers.contains(where: lowered.contains)
    }

    /// Gemini's list endpoint declares capability via
    /// `supportedGenerationMethods`; chat models support `generateContent`.
    /// A missing field passes (fail-open for proxies / older API versions);
    /// embeddings (`embedContent`), Imagen/Veo (`predict*`), and
    /// live-audio-only (`bidiGenerateContent`) models drop out. This check
    /// alone is not sufficient — Gemini's TTS and image-generation models
    /// *also* respond via `generateContent` (with audio/image response
    /// modalities), so the caller additionally applies the
    /// `isLikelyChatModelID` id heuristic to the stripped name.
    static func isChatCapableGemini(methods: [String]?) -> Bool {
        guard let methods else { return true }
        return methods.contains("generateContent")
    }

    /// Gemini returns fully-qualified resource names (`models/gemini-3-pro`);
    /// the wire-level id used everywhere else is the trailing segment.
    static func strippedGeminiName(_ name: String) -> String {
        if let slash = name.lastIndex(of: "/") {
            return String(name[name.index(after: slash)...])
        }
        return name
    }
}

/// OpenAI `/v1/models` envelope: `{ "data": [{ "id": "…" }, …] }`.
private struct OpenAIModelsResponse: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
}

/// Gemini `/v1beta/models` envelope: `{ "models": [{ "name": "models/…",
/// "supportedGenerationMethods": ["generateContent", …] }, …] }`. The methods
/// array is optional so proxies / older API versions that omit it still decode.
private struct GeminiModelsResponse: Decodable {
    struct Model: Decodable {
        let name: String
        let supportedGenerationMethods: [String]?
    }

    let models: [Model]
}
