import Core
import Foundation

// Keep Bundle.module lookup in Chat, where the prompt resources are bundled.
public enum ChatBriefing {
    /// Missing resources return empty text, which the assembler omits.
    public static func load() -> String {
        AppletSystemPrompt.load(from: .module, resource: "DefaultSystemPrompt")
    }

    /// Missing compact resources return empty text; the session then uses the full briefing.
    public static func loadCompact() -> String {
        AppletSystemPrompt.load(from: .module, resource: "DefaultSystemPrompt.compact")
    }
}
