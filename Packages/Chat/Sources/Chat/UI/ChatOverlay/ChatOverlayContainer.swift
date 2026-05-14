import SwiftUI

/// The shell's chat-overlay layer. Renders Chat in one of the three
/// ``ChatPresentationState`` shapes (expanded full-screen, semi-expanded
/// floating panel, minimized full-width pill) and handles snap transitions
/// triggered by the drag handle or the minimized pill tap.
///
/// State is owned by the shell (`AppShell` in the App target) so that
/// activating a non-Chat applet can demote chat to minimized externally,
/// and selecting Chat from the sidebar can promote it back to expanded.
/// The container itself only mutates state in response to user gestures
/// directly on its own surfaces.
public struct ChatOverlayContainer: View {
    @Binding public var state: ChatPresentationState
    @Bindable public var viewModel: ChatScreenViewModel
    /// Forwarded to the embedded chat surfaces.
    public let onManageModels: () -> Void
    /// Forwarded to the embedded chat surfaces.
    public let onAddModelRequested: @MainActor @Sendable () -> Void

    @MainActor
    public init(
        state: Binding<ChatPresentationState>,
        viewModel: ChatScreenViewModel,
        onManageModels: @escaping () -> Void = {},
        onAddModelRequested: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self._state = state
        self.viewModel = viewModel
        self.onManageModels = onManageModels
        self.onAddModelRequested = onAddModelRequested
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        GeometryReader { geo in
            // Use a VStack with a top `Spacer()` instead of `ZStack(alignment: .bottom)`
            // so the pill / panel reliably anchor to the bottom of the
            // viewport regardless of their intrinsic size. A ZStack with a
            // small child gets centered by SwiftUI even when the parent has
            // a fixed frame from the surrounding GeometryReader.
            VStack(spacing: 0) {
                switch state {
                case .expanded:
                    expandedLayout
                        .transition(.opacity)
                case .semiExpanded:
                    Spacer(minLength: 0)
                    semiExpandedLayout(in: geo)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                case .minimized:
                    Spacer(minLength: 0)
                    minimizedLayout
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(ChatOverlayAnimation.transition(reduceMotion: reduceMotion), value: state)
        }
    }

    // MARK: - Layouts

    @ViewBuilder
    private var expandedLayout: some View {
        ChatScreen(
            viewModel: viewModel,
            showsHeader: true,
            onManageModels: onManageModels,
            onAddModelRequested: onAddModelRequested,
            onDragHandleEnded: handleDragEnded
        )
    }

    @ViewBuilder
    private func semiExpandedLayout(in geo: GeometryProxy) -> some View {
        // Default panel height ≈ 52% of the viewport so the applet backdrop
        // remains visible behind it. `chat.jsx` shows the panel hugging the
        // bottom with the last ~3 messages and the composer pinned.
        SemiExpandedChatPanel(
            viewModel: viewModel,
            onManageModels: onManageModels,
            onAddModelRequested: onAddModelRequested,
            onDragHandleEnded: handleDragEnded
        )
        .frame(height: max(280, geo.size.height * 0.52))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var minimizedLayout: some View {
        MinimizedChatPill(onTap: { state = .semiExpanded })
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
    }

    // MARK: - Drag handling

    /// Translate a drag-end gesture into a snap target. Dragging *down*
    /// (positive height) collapses; dragging *up* (negative height)
    /// expands. A velocity above ``ChatOverlayAnimation/skipVelocity``
    /// causes the next-but-one state to be selected instead.
    private func handleDragEnded(translation: CGSize, predictedEndTranslation: CGSize) {
        let dy = translation.height
        // Predicted-end - actual = SwiftUI's velocity proxy (in points).
        let velocityProxy = predictedEndTranslation.height - translation.height
        let absDy = abs(dy)
        let absV = abs(velocityProxy)

        guard absDy >= ChatOverlayAnimation.snapDistance else {
            // Below the threshold — treat the gesture as a tap or
            // micro-drag and leave the state where it is.
            return
        }

        let direction: TransitionDirection = dy > 0 ? .collapsing : .expanding
        if absV > ChatOverlayAnimation.skipVelocity {
            state = state.skipTo(direction)
        } else if let next = state.step(toward: direction) {
            state = next
        }
    }
}
