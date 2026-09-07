import Foundation
import OSLog

/// Built-in OpenAI text-to-speech voices, ordered for the narration picker.
public enum OpenAISpeechVoice: String, CaseIterable, Codable, Sendable {
    case marin, cedar, alloy, ash, ballad, coral, echo, fable, nova, onyx, sage, shimmer, verse
    public var name: String { rawValue.capitalized }
}

/// Recoverable speech-generation failures; provider response bodies never reach the UI or logs.
public enum SpeechGenerationError: String, Error, Sendable, Equatable {
    case missingKey, invalidKey, authenticationFailed, permissionDenied, quotaExceeded, unavailable, invalidAudio, inputTooLong

    public var message: String {
        switch self {
        case .missingKey: "Add an OpenAI API key in Narration settings."
        case .invalidKey: "OpenAI rejected this API key. Update it in Settings."
        case .authenticationFailed: "OpenAI could not authorize speech generation. Check this key's permissions and project access in your OpenAI API settings."
        case .permissionDenied: "This OpenAI key needs permission to generate speech. Check its audio permissions and project access in your OpenAI API settings."
        case .quotaExceeded: "OpenAI's usage or rate limit was reached. Check your API account or try again later."
        case .unavailable: "OpenAI audio is unavailable. Check your connection or use an Apple voice."
        case .invalidAudio: "The downloaded audio could not be played. Try again or use an Apple voice."
        case .inputTooLong: "This passage is too long to generate as one audio clip."
        }
    }
}

/// Converts supplied text to MP3 audio without owning credentials or playback state.
public protocol SpeechGenerating: Sendable {
    func generate(text: String, voice: OpenAISpeechVoice, apiKey: String) async throws -> Data
}

/// Direct OpenAI speech transport. Requests happen only when the caller explicitly starts playback.
public struct OpenAISpeechGenerator: SpeechGenerating {
    public static let model = "gpt-4o-mini-tts-2025-12-15"
    public static let instruction = "Read naturally and clearly, with a calm, measured pace. Speak the supplied text without additions."
    private let http: any HTTPClient

    public init(http: any HTTPClient) { self.http = http }

    public func generate(text: String, voice: OpenAISpeechVoice, apiKey: String) async throws -> Data {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw SpeechGenerationError.missingKey }
        // A UTF-8 byte bound is conservative for tokenization, including non-ASCII text.
        guard !text.isEmpty, text.utf8.count <= 1_600 else { throw SpeechGenerationError.inputTooLong }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(input: text, voice: voice.rawValue))
        var bytes = Data()
        do {
            for try await chunk in http.stream(request) {
                try Task.checkCancellation()
                guard bytes.count + chunk.count <= 8 * 1_024 * 1_024 else {
                    throw SpeechGenerationError.invalidAudio
                }
                bytes.append(chunk)
            }
            try Task.checkCancellation()
            guard !bytes.isEmpty else { throw SpeechGenerationError.invalidAudio }
            return bytes
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SpeechGenerationError {
            throw error
        } catch HTTPError.badStatus(let status, let body) {
            let failure = responseFailure(status: status, body: body)
            // Only our closed set of failure names is logged. Provider messages can echo credentials.
            let logger = Logger(subsystem: "com.brianwang.Super.Core", category: "Speech")
            logger.error("OpenAI speech failed: HTTP \(status), reason=\(failure.rawValue, privacy: .public)")
            throw failure
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SpeechGenerationError.unavailable
        }
    }

    private func responseFailure(status: Int, body: String) -> SpeechGenerationError {
        if status == 401 || status == 403 {
            let detail = try? JSONDecoder().decode(ErrorBody.self, from: Data(body.utf8)).error
            if detail?.code == "invalid_api_key" { return .invalidKey }
            // Restricted keys can return 401 with a null code and a missing-scope explanation.
            let permissionCodes = ["insufficient_permissions", "missing_scope", "missing_scopes"]
            let message = detail?.message?.lowercased() ?? ""
            if permissionCodes.contains(detail?.code ?? "") || message.contains("missing scopes:") || message.contains("insufficient permissions") {
                return .permissionDenied
            }
            return status == 401 ? .authenticationFailed : .permissionDenied
        }
        return status == 429 ? .quotaExceeded : .unavailable
    }

    private struct ErrorBody: Decodable {
        let error: Detail

        struct Detail: Decodable {
            let code: String?
            let message: String?
        }
    }

    private struct Body: Encodable {
        let model = OpenAISpeechGenerator.model
        let instructions = OpenAISpeechGenerator.instruction
        let input: String
        let voice: String
        let response_format = "mp3"
        let speed = 1.0
    }
}
