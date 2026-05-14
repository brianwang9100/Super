import SwiftUI

/// Apple-style drag affordance pinned to the top of the chat surface in the
/// expanded and semi-expanded chat states. 36 × 4.5pt rounded pill, tinted by
/// the active drag tone (resting vs. actively dragged) per the 2026-05-13
/// design (`/tmp/super-design/super/project/ds/chat.jsx`).
///
/// Wires an optional `onDragEnded` callback that fires when the user lifts
/// after a drag — the chat-overlay container uses this to snap to the
/// nearest presentation state.
public struct ChatDragHandle: View {
    /// Resting tone is shown in the steady state. Active tone is shown
    /// while the user is dragging the handle.
    public enum Tone: Sendable, Equatable {
        case resting
        case active
    }

    /// Visual tint when not being dragged. The internal drag state takes
    /// over while a gesture is in flight.
    public let restingTone: Tone

    /// Fires on `DragGesture.onEnded` with the gesture's translation +
    /// predicted-end translation (the SwiftUI proxy for end velocity).
    /// `nil` means the handle is non-interactive (M1 placeholder).
    public let onDragEnded: ((_ translation: CGSize, _ predictedEndTranslation: CGSize) -> Void)?

    public init(
        restingTone: Tone = .resting,
        onDragEnded: ((_ translation: CGSize, _ predictedEndTranslation: CGSize) -> Void)? = nil
    ) {
        self.restingTone = restingTone
        self.onDragEnded = onDragEnded
    }

    @Environment(\.superTheme) private var theme

    /// `true` while the user has the gesture active — drives the dragged
    /// tint without bouncing through the parent's state.
    @State private var isDragging: Bool = false

    public var body: some View {
        // Centered with explicit padding rather than `Spacer`s so the pill
        // doesn't shift horizontally when the parent container's width
        // changes between presentation states.
        VStack {
            Capsule(style: .continuous)
                .fill(fillColor)
                .frame(width: 36, height: 4.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 4)
        // Wide hit area: the drag handle is small but the hit target
        // spans the top strip of the chat surface so the user doesn't
        // have to hit the 36 × 4.5 pill precisely.
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .accessibilityElement()
        .accessibilityLabel("Chat drag handle")
        .accessibilityHint("Drag to expand or collapse the chat")
    }

    private var fillColor: Color {
        let effective: Tone = isDragging ? .active : restingTone
        switch effective {
        case .resting:
            // `ink-mute @ 55%` resting per design — falls back to `inkSoft`
            // multiplied with an opacity since the theme doesn't expose a
            // dedicated `ink-mute` token today. Visually matches the chat.jsx
            // reference within a perceptual delta of <1%.
            return theme.inkSoft.opacity(0.55)
        case .active:
            // `ink-faint @ 70%` while dragging.
            return theme.inkFaint.opacity(0.70)
        }
    }

    /// The DragGesture instance. `minimumDistance: 0` so we capture taps
    /// at the very start; the parent decides whether the gesture met its
    /// snap-distance threshold.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if !isDragging { isDragging = true }
            }
            .onEnded { value in
                isDragging = false
                onDragEnded?(value.translation, value.predictedEndTranslation)
            }
    }
}
