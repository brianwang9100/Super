import Core
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

    /// Resolved chat-surface height for this anchor inside a container of
    /// `containerHeight` points, optionally offset by `bottomSafeArea` so
    /// the minimized anchor sits *above* the home indicator instead of
    /// behind it, and by `topInset` so the semi-expanded panel reserves
    /// space at the top for the backdrop applet's nav bar (handle lands
    /// at `y = topInset`). `topInset` only affects the `.semiExpanded`
    /// branch; the minimized pill and the expanded full screen ignore
    /// it by design.
    public func height(
        in containerHeight: CGFloat,
        bottomSafeArea: CGFloat = 0,
        topInset: CGFloat = 0
    ) -> CGFloat {
        switch self {
        case .minimized:
            return Self.minimizedBaseHeight + bottomSafeArea
        case .semiExpanded:
            return max(Self.semiExpandedMinHeight, containerHeight - topInset)
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
    /// `topInset` matches the semi-expanded anchor's reserve so a
    /// release in the band between the legacy ~52% anchor and the new
    /// "under nav bar" anchor still snaps to semi instead of jumping.
    public static func nearestAnchor(
        forHeight height: CGFloat,
        in containerHeight: CGFloat,
        bottomSafeArea: CGFloat = 0,
        topInset: CGFloat = 0
    ) -> ChatPresentationState {
        let scored: [(state: ChatPresentationState, delta: CGFloat)] = Self.allCases.map { state in
            (state, abs(state.height(in: containerHeight, bottomSafeArea: bottomSafeArea, topInset: topInset) - height))
        }
        return scored.min(by: { $0.delta < $1.delta })?.state ?? .semiExpanded
    }

    /// Vertical predicted-end translation (in points) above which a flick
    /// on release jumps straight to the endpoint anchor in the flick's
    /// direction. Compared against `predictedEndTranslation.height -
    /// translation.height` — SwiftUI's projection of how much further the
    /// gesture would travel given current velocity, which is a friendlier
    /// proxy than a raw points-per-second figure because the gesture
    /// callback hands it to us directly.
    public static let skipVelocity: CGFloat = 1_200

    /// Snap target on drag release. Combines the live release height with a
    /// velocity bias so:
    ///
    /// - A hard flick past ``skipVelocity`` jumps to the endpoint anchor in
    ///   the flick's direction (positive velocity = collapsing toward
    ///   `.minimized`).
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
        bottomSafeArea: CGFloat = 0,
        topInset: CGFloat = 0
    ) -> ChatPresentationState {
        if abs(velocity) >= Self.skipVelocity {
            return velocity > 0 ? .minimized : .expanded
        }
        let projectedHeight = currentHeight - velocity
        return nearestAnchor(
            forHeight: projectedHeight,
            in: containerHeight,
            bottomSafeArea: bottomSafeArea,
            topInset: topInset
        )
    }
}

// MARK: - Progress

extension ChatPresentationState {
    /// Progress threshold above which the composer's text editor is live
    /// and below which the chat reads as the minimized pill. The single
    /// source of truth for the pill ⇄ editor handover, shared by
    /// ``ChatComposer/editorInteractive`` (`> threshold`), `ChatScreen`'s
    /// `pillSurfaceCaptureActive` (`<= threshold`), and `ChatScreen`'s
    /// keyboard-dismiss-on-collapse `.onChange`. The `>` / `<=` split
    /// closes the off-by-one so a tap exactly on the boundary always lands
    /// on a live target.
    public static let editorInteractiveThreshold: Double = 0.15

    /// Whether `progress` just crossed *downward* past
    /// ``editorInteractiveThreshold`` — the chat collapsing far enough
    /// that the composer's editor goes non-interactive. `ChatScreen` uses
    /// this to dismiss the keyboard exactly once on that crossing.
    ///
    /// The predicate requires `oldProgress > newProgress`, so it returns
    /// `false` for every non-decreasing change: an expand — even one
    /// whose snap curve overshoots its target — only ever raises
    /// `progress`, so it can never trip a dismissal.
    public static func crossedBelowEditorThreshold(
        from oldProgress: Double,
        to newProgress: Double
    ) -> Bool {
        oldProgress > editorInteractiveThreshold
            && newProgress <= editorInteractiveThreshold
    }

    /// Maps an absolute chat-surface height to a `[0, 1]` progress where
    /// `0` is the minimized pill and `1` is the fully-expanded screen.
    /// `semiExpanded` lands at whatever fraction its height occupies along
    /// that axis — driven by `topInset`, so the value isn't fixed (see
    /// ``semiExpandedProgress(in:bottomSafeArea:topInset:)`` for the
    /// resolved mid-knot the backdrop dim curve reads).
    ///
    /// Downstream views (`ChatComposer`, `ChatScreen`, `AppShell`'s
    /// backdrop dim) interpolate their own visual parameters against this
    /// scalar so the entire chat surface moves with the finger during a
    /// drag rather than hopping between three discrete layouts.
    public static func progress(
        forHeight height: CGFloat,
        in containerHeight: CGFloat,
        bottomSafeArea: CGFloat = 0,
        topInset: CGFloat = 0
    ) -> Double {
        let minH = ChatPresentationState.minimized.height(in: containerHeight, bottomSafeArea: bottomSafeArea, topInset: topInset)
        let maxH = ChatPresentationState.expanded.height(in: containerHeight, bottomSafeArea: bottomSafeArea, topInset: topInset)
        guard maxH > minH else { return 0 }
        let raw = Double((height - minH) / (maxH - minH))
        return min(1, max(0, raw))
    }

    /// Resolved `[0, 1]` progress at the semi-expanded anchor for the
    /// given container geometry — the mid-knot of the backdrop's dim
    /// curve. Computed because the semi anchor no longer lives at a
    /// fixed fraction of the viewport (it's `containerHeight - topInset`),
    /// so the host can't hardcode the value the way the prior ratio
    /// allowed.
    public static func semiExpandedProgress(
        in containerHeight: CGFloat,
        bottomSafeArea: CGFloat = 0,
        topInset: CGFloat = 0
    ) -> Double {
        let semiH = semiExpanded.height(in: containerHeight, bottomSafeArea: bottomSafeArea, topInset: topInset)
        return progress(forHeight: semiH, in: containerHeight, bottomSafeArea: bottomSafeArea, topInset: topInset)
    }
}

// MARK: - Keyboard avoidance

extension ChatPresentationState {
    /// The chat surface's *rendered* height: the keyboard-free
    /// `effectiveHeight` (the settled/dragged anchor height that drives all
    /// the morph math) clamped to `keyboardAwareHeight` — the space left
    /// above the software keyboard — minus an optional `topInsetCap` the
    /// caller applies when it wants the surface's top edge fixed at
    /// `topInsetCap` rather than allowed to lift with the keyboard.
    ///
    /// Capping the rendered height here, rather than feeding the keyboard
    /// into the anchor math, is what keeps `progress` and the anchor
    /// envelope keyboard-independent: the chat's *logical* size never
    /// changes when a field is focused, only how much of it fits on screen.
    /// Because the surface is bottom-pinned, the plain cap
    /// `min(effectiveHeight, keyboardAwareHeight)` lifts its bottom edge to
    /// exactly the keyboard's top — fine for expanded/minimized where the
    /// top edge has no business staying put, but at the semi-expanded
    /// anchor we want the *top* edge fixed (handle stays under the
    /// backdrop applet's nav bar) and the *bottom* to shrink with the
    /// keyboard. Passing `topInsetCap = topInset` shrinks the available
    /// space from the top by the same inset the semi anchor reserves;
    /// callers pass `0` for every other state so the existing behavior
    /// holds.
    ///
    /// `keyboardAwareHeight` already equals the full container height when
    /// no keyboard is up, so with `topInsetCap = 0` this is a no-op
    /// (`effectiveHeight`) in that case.
    public static func renderedSurfaceHeight(
        effectiveHeight: CGFloat,
        keyboardAwareHeight: CGFloat,
        topInsetCap: CGFloat = 0
    ) -> CGFloat {
        // Floored at 0 so unusual geometry — landscape iPhone with a
        // full-screen keyboard, very short split-view window, anything
        // where `topInsetCap` exceeds `keyboardAwareHeight` — can't
        // produce a negative `.frame(height:)` that silently renders
        // nothing. The drag-time branch in `ChatOverlayMetrics.init`
        // already floors; pulling the floor into the function makes
        // both call paths safe.
        max(0, min(effectiveHeight, keyboardAwareHeight - topInsetCap))
    }
}

// MARK: - Migration notes

// Spring/crossfade animation tokens previously declared here as
// `ChatOverlayAnimation` now live in `Core.SuperMotion` so other applets
// adopting the same bottom-sheet morph can reuse them; the chat-specific
// `skipVelocity` (a snap-target-selection threshold, not an animation
// token) is hoisted onto ``ChatPresentationState`` itself above.
