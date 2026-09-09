import SwiftUI

@MainActor
public protocol MiniApplet: Sendable {
    /// Stable lowercase, dash-free identity used for routing, persistence, and deep links.
    var appletID: String { get }

    var displayName: String { get }

    func iconView(size: CGFloat) -> AnyView

    var accentColor: Color { get }

    func rootView() -> AnyView

    /// Creates optional temporary content for a record. The shell owns its native presentation.
    /// Call `onFinish` after nested sheets dismiss; returning nil declines the preview.
    func recordPreview(
        for reference: RecordReference,
        onFinish: @escaping @MainActor (RecordPreviewCompletion) -> Void
    ) -> AnyView?

    /// Leading Chat system guidance; empty bodies are omitted.
    var systemPrompt: String { get }

    /// Compact-window guidance; defaults to systemPrompt.
    var compactSystemPrompt: String { get }

    var suggestedChatActions: [SuggestedChatAction] { get }
}

public extension MiniApplet {
    func recordPreview(
        for reference: RecordReference,
        onFinish: @escaping @MainActor (RecordPreviewCompletion) -> Void
    ) -> AnyView? { nil }

    var suggestedChatActions: [SuggestedChatAction] { [] }

    var compactSystemPrompt: String { systemPrompt }
}
