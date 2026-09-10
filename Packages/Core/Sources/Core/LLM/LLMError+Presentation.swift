import Foundation

extension LLMError: LocalizedError {
    public var errorDescription: String? {
        if let detail { return "\(summary)\n\(detail)" }
        return summary
    }

    public var summary: String {
        switch self {
        case .unauthorized:
            return "Authentication failed. Check the API key in Settings."
        case .rateLimited:
            return "Rate limited by the model provider. Try again shortly."
        case .cancelled:
            return "Stopped."
        case .providerError(let code, _):
            let label = httpStatusLabel ?? code
            let suffix = label.isEmpty ? "" : " (\(label))"
            return "The model provider returned an error\(suffix)."
        case .requestFailed(let message), .decodingFailed(let message), .unsupportedModel(let message):
            return message
        }
    }

    public var detail: String? {
        guard case .providerError(_, let message) = self else { return nil }
        var body = message
        if let label = httpStatusLabel {
            if body == label { return nil }
            body = String(body.dropFirst("\(label): ".count))
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : body
    }

    private var httpStatusLabel: String? {
        guard case .providerError(let code, let message) = self,
              let status = Int(code), (100...599).contains(status), code == String(status)
        else { return nil }
        // HTTP adapters include this prefix; provider-defined codes can also be numeric.
        let label = "HTTP \(code)"
        return message == label || message.hasPrefix("\(label): ") ? label : nil
    }
}
