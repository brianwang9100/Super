import SwiftUI

/// The three discrete shapes Chat takes when the shell is hosting another
/// applet behind it (or when Chat itself is active and fills the screen).
///
/// Transitions between states are user-driven (drag the drag handle, tap the
/// minimized pill, select Chat from the sidebar) and animate via the spring
/// in ``ChatOverlayAnimation``. Reduce Motion replaces the spring with a
/// short crossfade per `docs/DESIGN.md §4.4` and §10.
public enum ChatPresentationState: Sendable, Equatable, CaseIterable {
    /// Chat fills the screen. The applet backdrop is hidden behind it. Drag
    /// the chat-surface handle down to collapse to ``semiExpanded``.
    case expanded

    /// Floating chat panel pinned to the bottom of the viewport: drag handle
    /// on top, last few messages preview, composer pill. The applet backdrop
    /// is visible at 0.65 opacity behind it.
    case semiExpanded

    /// Full-width "Chat with Super" pill at the very bottom. The applet
    /// backdrop owns the full screen at 1.0 opacity behind it. Tap the pill
    /// to climb to ``semiExpanded``.
    case minimized

    /// Single-step transition driver. `direction` is the gesture's
    /// intended motion (`.collapsing` = drag down; `.expanding` = drag
    /// up). Returns the adjacent state, or `nil` when the current state
    /// is already the endpoint in that direction.
    public func step(toward direction: TransitionDirection) -> ChatPresentationState? {
        switch (direction, self) {
        case (.collapsing, .expanded): .semiExpanded
        case (.collapsing, .semiExpanded): .minimized
        case (.collapsing, .minimized): nil
        case (.expanding, .expanded): nil
        case (.expanding, .semiExpanded): .expanded
        case (.expanding, .minimized): .semiExpanded
        }
    }

    /// Skip-to-endpoint variant used when a flick exceeds the velocity
    /// threshold. Always returns the terminal state in the chosen
    /// direction regardless of where you started — only `.expanded ↔
    /// .minimized` actually skips a state; from `.semiExpanded` the
    /// result is the same as `step(toward:)`. Same is true from the
    /// terminal states themselves (idempotent).
    public func skipTo(_ direction: TransitionDirection) -> ChatPresentationState {
        switch direction {
        case .collapsing: .minimized
        case .expanding: .expanded
        }
    }
}

/// Drag direction the user is moving the chat surface in. `.collapsing`
/// shrinks the chat (expanded → semi → minimized); `.expanding` grows it.
public enum TransitionDirection: Sendable, Equatable {
    case collapsing
    case expanding
}

// MARK: - Animation tokens

/// Spring + crossfade tokens used by the chat-overlay container. Match the
/// 2026-05-13 design spec (`/tmp/super-design/super/project/ds/chat.jsx`):
/// `cubic-bezier(0.34, 1.4, 0.5, 1)` over 380ms.
public enum ChatOverlayAnimation {
    /// The default state-transition spring. Lifts up on overshoot for a
    /// soft Apple-style settle.
    public static let snap: Animation = .timingCurve(0.34, 1.4, 0.5, 1, duration: 0.38)

    /// Reduce-Motion fallback — replaces the spring with a short crossfade.
    public static let reducedMotion: Animation = .easeInOut(duration: 0.2)

    /// Returns the appropriate animation given the environment's
    /// `accessibilityReduceMotion` value.
    public static func transition(reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedMotion : snap
    }

    /// Distance (in points) the user has to drag past the current snap
    /// point before a release will move to the adjacent state. Below this
    /// threshold the drag rubber-bands back to the current state.
    public static let snapDistance: CGFloat = 60

    /// Vertical velocity (points/sec) above which a flick skips a state.
    /// 1,200 pt/s is roughly an Apple-style flick threshold tuned to feel
    /// decisive but not trigger on slow drags.
    public static let skipVelocity: CGFloat = 1_200
}
