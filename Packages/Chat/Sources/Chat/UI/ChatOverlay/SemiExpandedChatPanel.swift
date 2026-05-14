import SwiftUI

/// Floating chat panel pinned to the bottom of the viewport in the
/// ``ChatPresentationState/semiExpanded`` state. Wraps `ChatScreen` with
/// the header hidden, embedded inside a rounded translucent surface with a
/// blurred backdrop, soft border, and two-layer drop shadow.
///
/// Per the 2026-05-13 design (`chat.jsx` → `StateSemi`): left/right/bottom
/// inset 10pt, corner radius 22pt, max height ≈ 52% of the viewport so the
/// applet backdrop stays partially visible behind it.
public struct SemiExpandedChatPanel: View {
    @Bindable public var viewModel: ChatScreenViewModel
    /// Forwarded to the embedded chat surface — opens Settings on the
    /// Models pane when the user picks "Manage models…" from the composer
    /// dropdown.
    public let onManageModels: () -> Void
    /// Forwarded to the chat view model's add-model-request callback —
    /// fires from the no-model error banner's CTA.
    public let onAddModelRequested: @MainActor @Sendable () -> Void
    /// Forwarded to the embedded `ChatDragHandle`. The chat-overlay
    /// container wires this to snap-to-state behavior on drag end.
    public let onDragHandleEnded: ((_ translation: CGSize, _ predictedEndTranslation: CGSize) -> Void)?

    @MainActor
    public init(
        viewModel: ChatScreenViewModel,
        onManageModels: @escaping () -> Void = {},
        onAddModelRequested: @escaping @MainActor @Sendable () -> Void = {},
        onDragHandleEnded: ((_ translation: CGSize, _ predictedEndTranslation: CGSize) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onManageModels = onManageModels
        self.onAddModelRequested = onAddModelRequested
        self.onDragHandleEnded = onDragHandleEnded
    }

    @Environment(\.superTheme) private var theme

    public var body: some View {
        // Constrain the panel to ~52% of the parent so the applet backdrop
        // remains visible behind it. Uses a GeometryReader at the call site
        // (in `ChatOverlayContainer`) to compute concrete bounds; here we
        // just stretch to whatever the container gives us, capped at a
        // sensible default in case it's used standalone.
        ChatScreen(
            viewModel: viewModel,
            showsHeader: false,
            onManageModels: onManageModels,
            onAddModelRequested: onAddModelRequested,
            onDragHandleEnded: onDragHandleEnded
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(theme.backgroundRaised.opacity(0.95))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(theme.borderFaint, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 12)
        .shadow(color: Color.black.opacity(0.12), radius: 30, x: 0, y: 30)
    }
}
