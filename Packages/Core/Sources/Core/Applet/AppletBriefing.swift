import Foundation

/// One applet's labeled contribution to the leading Chat system message.
///
/// `label` is rendered as a `## <label>` markdown header so the Large
/// Language Model (LLM) can scope each applet's behavioral rules. `body`
/// is the trimmed prompt text from the applet's bundled `SystemPrompt.md`
/// — never empty here, since the registry drops empty bodies before
/// constructing the briefing.
public struct AppletBriefing: Sendable, Equatable {
    /// The contributing applet's `appletID`. Lets the orchestrator scope the
    /// briefing set per turn (e.g. active-applet-only on small-window models)
    /// without re-consulting the registry. Empty for hand-built fixtures that
    /// don't model an applet identity.
    public let appletID: String
    public let label: String
    public let body: String
    /// Short variant of `body` for small-context-window models, resolved from
    /// the applet's `compactSystemPrompt`. Falls back to `body` when the
    /// applet has no compact variant, so callers can always read this on the
    /// compact tier without a nil-check.
    public let compactBody: String

    public init(label: String, body: String, compactBody: String? = nil, appletID: String = "") {
        self.appletID = appletID
        self.label = label
        self.body = body
        self.compactBody = compactBody ?? body
    }
}
