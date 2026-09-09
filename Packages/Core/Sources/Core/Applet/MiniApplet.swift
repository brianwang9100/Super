import SwiftUI

@MainActor
public protocol MiniApplet: Sendable {
    /// Stable lowercase, dash-free identity used for routing, persistence, and deep links.
    var appletID: String { get }

    var displayName: String { get }

    func iconView(size: CGFloat) -> AnyView

    var accentColor: Color { get }

    func rootView() -> AnyView

    /// Bundled LLM guidance; the registry omits empty bodies.
    var systemPrompt: String { get }

    /// Compact-window guidance; defaults to systemPrompt.
    var compactSystemPrompt: String { get }

    var suggestedChatActions: [SuggestedChatAction] { get }
}

public extension MiniApplet {
    var suggestedChatActions: [SuggestedChatAction] { [] }

    var compactSystemPrompt: String { systemPrompt }
}
