import SwiftUI

/// The three settled positions Chat can rest at when the shell is hosting
/// another applet behind it (or when Chat itself is active and fills the
/// screen).
///
/// The chat surface moves continuously under the user's finger during a
/// drag; on release it snaps to whichever of these anchors is nearest the
/// release height (with a velocity bias for flicks). The enum represents
/// only the *settled* anchor — the live in-flight height during a drag is
/// stored alongside it on the overlay.
public enum ChatPresentationState: Sendable, Equatable, CaseIterable {
    /// Chat fills the screen. The applet backdrop is hidden behind it.
    case expanded

    /// Floating chat panel pinned to the bottom of the viewport, with the
    /// applet backdrop dimmed and visible behind it.
    case semiExpanded

    /// Full-width "Chat with Super" pill at the very bottom. The applet
    /// backdrop owns the full screen behind it.
    case minimized
}

// MARK: - Anchor geometry

extension ChatPresentationState {
    /// Pill-mode total chat height before the bottom safe-area inset is
    /// added. Sized tightly to fit *just* the always-visible drag handle
    /// (~16.5pt) + the morphing composer's intrinsic pill height
    /// (~76pt = 34pt editor row + 12pt capsule padding × 2 + 14pt bottom
    /// outer padding + 4pt VStack spacing) plus a few points of slack
    /// for the visible gap between handle and pill. Anything taller and
    /// the chat-surface VStack's flexible content slot soaks up the
    /// leftover, pushing the handle visibly away from the pill. The
    /// numeric value targets ≈4pt of visible gap on iPhone 17 at
    /// default Dynamic Type — see the AX dump in PR notes.
    public static let minimizedBaseHeight: CGFloat = 60

    /// Minimum semi-expanded height regardless of viewport — keeps the
    /// floating panel readable on small screens. The previous swap-based
    /// container used the same floor.
    public static let semiExpandedMinHeight: CGFloat = 280

    /// Semi-expanded height as a fraction of the viewport when the
    /// fractional value exceeds ``semiExpandedMinHeight``. Matches the
    /// 2026-05-13 design (`chat.jsx` → `StateSemi`, ≈52% of the viewport).
    public static let semiExpandedRatio: CGFloat = 0.52

    /// Resolved chat-surface height for this anchor inside a container of
    /// `containerHeight` points, optionally offset by `bottomSafeArea` so
    /// the minimized anchor sits *above* the home indicator instead of
    /// behind it.
    public func height(in containerHeight: CGFloat, bottomSafeArea: CGFloat = 0) -> CGFloat {
        switch self {
        case .minimized:
            return Self.minimizedBaseHeight + bottomSafeArea
        case .semiExpanded:
            return max(Self.semiExpandedMinHeight, containerHeight * Self.semiExpandedRatio)
        case .expanded:
            return containerHeight
        }
    }
}

// MARK: - Snap selection

extension ChatPresentationState {
    /// Returns the anchor whose height is closest to `height` inside a
    /// container of `containerHeight` points. Used after a drag release
    /// to settle the chat to the nearest of the three rest positions.
    public static func nearestAnchor(
        forHeight height: CGFloat,
        in containerHeight: CGFloat,
        bottomSafeArea: CGFloat = 0
    ) -> ChatPresentationState {
        let scored: [(state: ChatPresentationState, delta: CGFloat)] = Self.allCases.map { state in
            (state, abs(state.height(in: containerHeight, bottomSafeArea: bottomSafeArea) - height))
        }
        return scored.min(by: { $0.delta < $1.delta })?.state ?? .semiExpanded
    }

    /// Snap target on drag release. Combines the live release height with a
    /// velocity bias so:
    ///
    /// - A hard flick past ``ChatOverlayAnimation/skipVelocity`` jumps to
    ///   the endpoint anchor in the flick's direction (positive velocity =
    ///   collapsing toward `.minimized`).
    /// - A softer release projects the height forward by `velocity` and
    ///   snaps to the nearest anchor for that projected height, so a
    ///   medium drag with momentum settles past the geometric midpoint.
    ///
    /// `velocity` is SwiftUI's predicted-end-translation delta along the
    /// y-axis (`predictedEndTranslation.height - translation.height`) —
    /// positive when the user is dragging downward (collapsing), negative
    /// when dragging up (expanding). SwiftUI projects this ~0.16s ahead
    /// of the release, which we treat as the natural decel horizon and
    /// add directly to the release height with the sign flipped (downward
    /// translation = height shrinks).
    public static func snapTarget(
        currentHeight: CGFloat,
        velocity: CGFloat,
        containerHeight: CGFloat,
        bottomSafeArea: CGFloat = 0
    ) -> ChatPresentationState {
        if abs(velocity) >= ChatOverlayAnimation.skipVelocity {
            return velocity > 0 ? .minimized : .expanded
        }
        let projectedHeight = currentHeight - velocity
        return nearestAnchor(
            forHeight: projectedHeight,
            in: containerHeight,
            bottomSafeArea: bottomSafeArea
        )
    }
}

// MARK: - Progress

extension ChatPresentationState {
    /// Maps an absolute chat-surface height to a `[0, 1]` progress where
    /// `0` is the minimized pill and `1` is the fully-expanded screen.
    /// `semiExpanded` lands at whatever fraction its height occupies along
    /// that axis (typically ≈0.52, matching ``semiExpandedRatio``).
    ///
    /// Downstream views (`ChatComposer`, `ChatScreen`, `AppShell`'s
    /// backdrop dim) interpolate their own visual parameters against this
    /// scalar so the entire chat surface moves with the finger during a
    /// drag rather than hopping between three discrete layouts.
    public static func progress(
        forHeight height: CGFloat,
        in containerHeight: CGFloat,
        bottomSafeArea: CGFloat = 0
    ) -> Double {
        let minH = ChatPresentationState.minimized.height(in: containerHeight, bottomSafeArea: bottomSafeArea)
        let maxH = ChatPresentationState.expanded.height(in: containerHeight, bottomSafeArea: bottomSafeArea)
        guard maxH > minH else { return 0 }
        let raw = Double((height - minH) / (maxH - minH))
        return min(1, max(0, raw))
    }
}

// MARK: - Animation tokens

/// Spring + crossfade tokens used by the chat-overlay surface. Match the
/// 2026-05-13 design spec (`/tmp/super-design/super/project/ds/chat.jsx`):
/// `cubic-bezier(0.34, 1.4, 0.5, 1)` over 380ms.
public enum ChatOverlayAnimation {
    /// The default snap-to-anchor spring on drag release. Lifts up on
    /// overshoot for a soft Apple-style settle.
    public static let snap: Animation = .timingCurve(0.34, 1.4, 0.5, 1, duration: 0.38)

    /// Reduce-Motion fallback — replaces the spring with a short crossfade.
    public static let reducedMotion: Animation = .easeInOut(duration: 0.2)

    /// Returns the appropriate animation given the environment's
    /// `accessibilityReduceMotion` value.
    public static func transition(reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedMotion : snap
    }

    /// Vertical predicted-end translation (in points) above which a flick
    /// on release jumps straight to the endpoint anchor in the flick's
    /// direction. Compared against `predictedEndTranslation.height -
    /// translation.height` — SwiftUI's projection of how much further the
    /// gesture would travel given current velocity, which is a friendlier
    /// proxy than a raw points-per-second figure because the gesture
    /// callback hands it to us directly.
    public static let skipVelocity: CGFloat = 1_200
}
