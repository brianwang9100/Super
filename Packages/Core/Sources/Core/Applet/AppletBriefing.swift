import Foundation

/// One applet's labeled contribution to the leading Chat system message.
///
/// `label` is rendered as a `## <label>` markdown header so the Large
/// Language Model (LLM) can scope each applet's behavioral rules. `body`
/// is the trimmed prompt text from the applet's bundled `SystemPrompt.md`
/// — never empty here, since the registry drops empty bodies before
/// constructing the briefing.
public struct AppletBriefing: Sendable, Equatable {
    public let label: String
    public let body: String

    public init(label: String, body: String) {
        self.label = label
        self.body = body
    }
}
