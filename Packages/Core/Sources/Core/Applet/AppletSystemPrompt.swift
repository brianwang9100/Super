import Foundation

/// Missing or unreadable prompts resolve to an empty string and are skipped downstream.
public enum AppletSystemPrompt {
    public static func load(from bundle: Bundle, resource: String = "SystemPrompt") -> String {
        guard let url = bundle.url(forResource: resource, withExtension: "md") else {
            return ""
        }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
