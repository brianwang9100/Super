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
/// Two wire formats, dispatched by `kind`:
/// - `.openAICompatible` (OpenAI, Anthropic's `/v1/openai/` shim, xAI):
///   `Authorization: Bearer`, response `{ data: [{ id }] }`.
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
        case gemini
    }

    public func listModelIDs(kind: LLMProviderKind, baseURL: URL, apiKey: String?) async throws -> [String] {
        let format: WireFormat
        switch kind {
        case .openAICompatible:
            format = .openAICompatible
        case .geminiNative:
            format = .gemini
        case .appleFoundation, .anthropicNative, .openAIResponses:
            throw ModelListingError.unsupportedKind(kind)
        #if DEBUG
        case .debug:
            throw ModelListingError.unsupportedKind(kind)
        #endif
        }

        let url = Self.modelsURL(baseURL: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Same cleartext gate as the completions path: never attach a
        // credential over a non-loopback `http://` endpoint, regardless of
        // header name. See `URLSecurity.swift`.
        if let apiKey, !apiKey.isEmpty, isCleartextSafeForCredentials(url) {
            switch format {
            case .openAICompatible:
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            case .gemini:
                request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            }
        }

        let data = try await drain(request)

        switch format {
        case .openAICompatible:
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
    /// `/chat/completions`. So `…/v1`, `…/v1/`, and `…/v1/openai/` all yield
    /// `…/models` correctly.
    static func modelsURL(baseURL: URL) -> URL {
        let suffix = "/models"
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL.appending(path: "models")
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix(suffix) { path += suffix }
        components.path = path
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
