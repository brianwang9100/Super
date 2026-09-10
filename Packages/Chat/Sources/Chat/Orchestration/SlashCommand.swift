import Foundation

/// Recognized commands dispatch directly without persisting a user message.
public enum SlashCommand: Sendable, Equatable {
    case compact

    public init?(rawText: String) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "/compact":
            self = .compact
        default:
            return nil
        }
    }
}
