import SwiftUI

/// Apple-style drag affordance pinned to the top of the chat surface. 36 ×
/// 4.5pt rounded pill, tinted by the active drag tone (resting vs. actively
/// dragged) per the 2026-05-13 design (`/tmp/super-design/super/project/ds/chat.jsx`).
///
/// Fires two callbacks the chat overlay wires together to resize the chat
/// surface continuously under the finger and snap to the nearest anchor on
/// release:
///
/// - `onDragChanged(translation)` — fires on every `DragGesture.onChanged`
///   tick during a drag; the overlay updates `dragHeight` so the chat's
///   frame tracks the finger.
/// - `onDragEnded(translation, predictedEndTranslation)` — fires once on
///   release with SwiftUI's predicted-end translation (the velocity proxy);
///   the overlay computes the snap target from height + velocity.
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

    /// Fires on every `DragGesture.onChanged` tick with the live
    /// translation. The chat overlay uses this to drive `dragHeight`
    /// continuously so the chat surface tracks the finger. `nil` means
    /// the handle is non-interactive.
    public let onDragChanged: ((_ translation: CGSize) -> Void)?

    /// Fires on `DragGesture.onEnded` with the gesture's translation +
    /// predicted-end translation (the SwiftUI proxy for end velocity).
    /// `nil` means the handle is non-interactive (M1 placeholder).
    public let onDragEnded: ((_ translation: CGSize, _ predictedEndTranslation: CGSize) -> Void)?

    public init(
        restingTone: Tone = .resting,
        onDragChanged: ((_ translation: CGSize) -> Void)? = nil,
        onDragEnded: ((_ translation: CGSize, _ predictedEndTranslation: CGSize) -> Void)? = nil
    ) {
        self.restingTone = restingTone
        self.onDragChanged = onDragChanged
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
    /// at the very start; the parent decides whether the drag commits
    /// (height projection) or rubber-bands back (small jitter on tap).
    ///
    /// `coordinateSpace: .global` is load-bearing: the drag handle sits at
    /// the top of the chat surface, which itself resizes (and so the
    /// handle moves down or up) in response to the very drag this gesture
    /// drives. In the default `.local` space the translation would be
    /// reported relative to the moving handle frame, which closes a
    /// feedback loop that makes the chat resize at half the finger
    /// speed. `.global` reports true screen-pixel displacement, so the
    /// chat tracks the finger 1:1.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if !isDragging { isDragging = true }
                onDragChanged?(value.translation)
            }
            .onEnded { value in
                isDragging = false
                onDragEnded?(value.translation, value.predictedEndTranslation)
            }
    }
}
