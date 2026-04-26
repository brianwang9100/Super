import Foundation

/// Composer-side slash commands recognized at submission time. The composer
/// parses the raw text via `init?(rawText:)`; if a command matches it
/// dispatches to the relevant `ChatSession` entry point instead of writing
/// a user `MessageRecord`.
public enum SlashCommand: Sendable, Equatable {
    /// Manual compaction trigger.
    case compact

    /// Returns the matching command, or nil if `rawText` (after trimming
    /// whitespace) is not a recognized slash command.
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
