import Foundation

/// Registry output trims prompt bodies and omits empty ones; labels become Markdown section headings.
public struct AppletBriefing: Sendable, Equatable {
    /// Identifies the contributor for per-turn scope filtering; empty for anonymous fixtures.
    public let appletID: String
    public let label: String
    public let body: String
    /// Falls back to body when no compact variant is supplied.
    public let compactBody: String

    public init(label: String, body: String, compactBody: String? = nil, appletID: String = "") {
        self.appletID = appletID
        self.label = label
        self.body = body
        self.compactBody = compactBody ?? body
    }
}
