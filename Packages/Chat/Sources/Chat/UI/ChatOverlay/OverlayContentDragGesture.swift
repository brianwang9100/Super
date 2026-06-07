import SwiftUI

/// Pure decision logic for the content-drag → overlay-drag handoff. Kept free
/// of UIKit so every branch is unit-testable without a device or simulator.
///
/// The chat transcript is a `ScrollView`. A single finger-drag on it can either
/// scroll the content or resize the chat overlay, decided by **where the scroll
/// sat when the gesture began** — an arm-at-start latch, not a live per-tick
/// edge check:
///
/// - began **at the top** → a downward drag **collapses** (minimize);
/// - began **at the bottom** → an upward drag **expands** (maximize);
/// - began **mid-content** → the scroll view keeps the whole gesture, even if
///   scrolling reaches an edge partway through (the latch was set at `.began`).
///
/// The arm flags (``armedCollapse`` / ``armedExpand``) are computed once by the
/// coordinator at `.began` and held constant for the gesture; they fold in both
/// the edge-at-start and the overlay's remaining capability. Once a drag
/// **engages** resize it **stays in resize** until release (sheet-like) — there
/// is no reverse-past-anchor hand-back to the scroll view. The engaged edge is
/// tracked so a reversal that crosses the anchor keeps pinning the same edge
/// rather than flipping.
struct OverlayDragArbiter {
    /// Which scroll edge a resize handoff engaged from. Tracked across the
    /// gesture so the pin stays put when an engaged drag reverses past the
    /// anchor (stay-in-resize can drive displacement through 0).
    enum ScrollEdge: Equatable {
        case top
        case bottom
    }

    /// Live scroll geometry sampled at the current tick.
    struct ScrollState: Equatable {
        /// Current vertical content offset.
        let offsetY: CGFloat
        /// Offset value at the top edge (`-adjustedContentInset.top`).
        let topOffsetY: CGFloat
        /// Offset value at the bottom edge
        /// (`contentSize.height - bounds.height + adjustedContentInset.bottom`),
        /// floored at `topOffsetY` for short content.
        let bottomOffsetY: CGFloat
        /// `false` when the content can't scroll (empty state, or content
        /// shorter than the viewport) — the overlay drives from the first tick.
        let isScrollable: Bool

        /// Tolerance (points) for treating an offset as "at the edge" — absorbs
        /// the sub-pixel rest offset a `ScrollView` settles at.
        static let edgeEpsilon: CGFloat = 0.5

        var atTop: Bool { offsetY <= topOffsetY + Self.edgeEpsilon }
        var atBottom: Bool { offsetY >= bottomOffsetY - Self.edgeEpsilon }
    }

    /// The result of integrating one pan tick.
    struct Step: Equatable {
        /// The overlay's new signed displacement from its settled anchor, in
        /// points. `> 0` collapsing (dragged down from the top edge), `< 0`
        /// expanding (dragged up from the bottom edge), `0` not engaged (scroll
        /// view owns the gesture). Fed straight to the overlay's drag callback
        /// as a translation — matching what `ChatDragHandle` feeds (positive
        /// height collapses, negative expands). Under stay-in-resize an engaged
        /// drag may drive this back through 0 and out the other side without
        /// handing control back to the scroll view.
        let overlayDisplacement: CGFloat
        /// When `true`, the inner scroll view must be pinned to ``pinnedOffsetY``
        /// this tick so the finger drives the overlay instead of scrolling.
        /// When `false`, the scroll view owns the tick and scrolls normally.
        let pinScroll: Bool
        /// The content offset to pin the scroll view at while driving (the top
        /// or bottom edge). Only meaningful when ``pinScroll`` is `true`.
        let pinnedOffsetY: CGFloat
    }

    /// Integrate a single pan tick into the overlay's displacement.
    ///
    /// - Parameters:
    ///   - scroll: live scroll geometry this tick (used for the pin offsets).
    ///   - deltaY: pan translation change since the previous tick (points);
    ///     positive = finger moving down (scrolling the content toward its top
    ///     edge); negative = finger moving up.
    ///   - previousDisplacement: the overlay's signed displacement carried from
    ///     the previous tick (see ``Step/overlayDisplacement``).
    ///   - engagedEdge: the edge this gesture engaged resize from, or `nil` if
    ///     it hasn't engaged yet. Once non-`nil` the gesture stays in resize and
    ///     keeps pinning that edge (stay-in-resize, flip-proof across a reversal
    ///     through the anchor). The coordinator sets it on first engagement.
    ///   - armedCollapse: whether a downward drag may engage collapse — latched
    ///     at `.began` from "scroll was at the top (or non-scrollable)" AND the
    ///     overlay can still shrink. Constant for the gesture.
    ///   - armedExpand: whether an upward drag may engage expand — latched at
    ///     `.began` from "scroll was at the bottom (or non-scrollable)" AND the
    ///     overlay can still grow. Constant for the gesture.
    /// - Returns: the integrated ``Step`` for this tick.
    func step(
        scroll: ScrollState,
        deltaY: CGFloat,
        previousDisplacement: CGFloat,
        engagedEdge: ScrollEdge?,
        armedCollapse: Bool,
        armedExpand: Bool
    ) -> Step {
        // Already engaged: stay in resize for the rest of the gesture, pinned at
        // the edge we engaged from. Keep driving even if the finger reverses
        // through the anchor — no hand-back to the scroll view.
        if let engagedEdge {
            let pinnedOffsetY = engagedEdge == .top ? scroll.topOffsetY : scroll.bottomOffsetY
            return Step(
                overlayDisplacement: previousDisplacement + deltaY,
                pinScroll: true,
                pinnedOffsetY: pinnedOffsetY
            )
        }

        // Not engaged: the scroll view owns the gesture unless this drag was
        // armed (at the matching edge) when it began. Because the arm flags are
        // latched at `.began`, scrolling *into* an edge mid-gesture never
        // engages — the gesture stays a scroll.
        let draggingDown = deltaY > 0
        let draggingUp = deltaY < 0
        if draggingDown && armedCollapse {
            return Step(overlayDisplacement: deltaY, pinScroll: true, pinnedOffsetY: scroll.topOffsetY)
        }
        if draggingUp && armedExpand {
            return Step(overlayDisplacement: deltaY, pinScroll: true, pinnedOffsetY: scroll.bottomOffsetY)
        }
        return Step(overlayDisplacement: 0, pinScroll: false, pinnedOffsetY: scroll.offsetY)
    }
}

/// UIKit deceleration projection of a flick: how far (points) a surface would
/// coast to rest given an initial velocity (points/sec). Mirrors the WWDC
/// "Designing Fluid Interfaces" formula so the synthesized predicted-end
/// translation lands on the same scale as SwiftUI's `predictedEndTranslation`
/// that `ChatDragHandle` feeds into `ChatPresentationState.snapTarget`.
func overlayDragProjection(velocityY: CGFloat, decelerationRate: CGFloat = 0.998) -> CGFloat {
    (velocityY / 1000) * decelerationRate / (1 - decelerationRate)
}

/// Pure geometry behind the content-drag locator's fallback (see
/// `Coordinator.transcriptScrollView(in:at:)`): given candidate scroll-view
/// frames in **back-to-front order** (window coordinates), the index of the
/// **frontmost** one that contains `point` and is **not** the full-window
/// backdrop, or `nil` if none qualifies.
///
/// This encodes the fix's core rule — pick the inset chat transcript under the
/// finger, never the full-window backdrop applet behind it, and resolve to
/// "nothing" (→ drive immediately) in the empty state where only the backdrop
/// sits under the touch. Factored out of the UIKit walk so it's unit-tested on
/// macOS without a `UIView` hierarchy.
///
/// "Full-window backdrop" is a frame that spans the window **top-to-bottom**
/// (origin at the top, extending to the bottom edge). The chat transcript is
/// always inset below the surface chrome (handle/header) so its frame starts
/// below the top — it is never excluded, even when it reaches the bottom edge.
/// The 1-point epsilons absorb sub-point safe-area rounding on the backdrop.
func frontmostInsetScrollIndex(
    frames: [CGRect],
    containing point: CGPoint,
    windowHeight: CGFloat
) -> Int? {
    // `frames` is back-to-front, so scan in reverse and return the first hit —
    // that's the frontmost match (the transcript composited over the backdrop).
    for index in frames.indices.reversed() {
        let frame = frames[index]
        let coversWindow = frame.minY <= 1 && frame.maxY >= windowHeight - 1
        if !coversWindow, frame.contains(point) { return index }
    }
    return nil
}

extension View {
    /// Attach the content-drag → overlay-drag handoff gesture. On UIKit
    /// platforms it wraps a `UIPanGestureRecognizer` that recognizes
    /// simultaneously with the inner scroll view's pan and hands off to the
    /// overlay at the scroll edges; on macOS (no touch / scroll-pan to
    /// coordinate with) it's a no-op so the package still compiles for tests.
    ///
    /// `onChanged` / `onEnded` are the same callbacks `ChatDragHandle` uses —
    /// the overlay can't tell which input drove the drag.
    ///
    /// `resetToken` is bumped by the overlay whenever the surface settles into a
    /// new anchor or the keyboard shows/hides; a change clears the coordinator's
    /// per-gesture latches so no stale arm/displacement state from the prior
    /// interaction bleeds into the next handoff decision.
    func overlayContentDrag(
        canExpand: Bool,
        canCollapse: Bool,
        resetToken: Int,
        onChanged: @escaping (CGSize) -> Void,
        onEnded: @escaping (CGSize, CGSize) -> Void
    ) -> some View {
        #if canImport(UIKit)
        gesture(
            OverlayContentDragGesture(
                onChanged: onChanged,
                onEnded: onEnded,
                canExpand: canExpand,
                canCollapse: canCollapse,
                resetToken: resetToken
            )
        )
        #else
        self
        #endif
    }
}

#if canImport(UIKit)
import UIKit

/// Bridges a `UIPanGestureRecognizer` into SwiftUI so a drag anywhere on the
/// chat content either scrolls the transcript or resizes the chat overlay,
/// decided by where the scroll sat when the gesture began (arm-at-start). The
/// per-tick integration lives in the pure ``OverlayDragArbiter``; this type
/// samples live scroll geometry, latches the arm flags + engaged edge for the
/// gesture, pins the scroll view while the overlay drives, and forwards the
/// result to the overlay's drag callbacks.
struct OverlayContentDragGesture: UIGestureRecognizerRepresentable {
    let onChanged: (CGSize) -> Void
    let onEnded: (CGSize, CGSize) -> Void
    /// Whether the overlay can still grow / shrink from its current settled
    /// anchor. Refreshed onto the coordinator on every SwiftUI update (see
    /// ``updateUIGestureRecognizer``); the arbiter reads them live on each
    /// at-anchor tick to gate the *start* of a handoff (don't begin driving in
    /// a direction the overlay can't move).
    let canExpand: Bool
    let canCollapse: Bool
    /// Bumped by the overlay on every settle / keyboard toggle. A change clears
    /// the coordinator's latched per-gesture state (see ``Coordinator/reset()``).
    let resetToken: Int

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        let coordinator = Coordinator(onChanged: onChanged, onEnded: onEnded)
        coordinator.canExpand = canExpand
        coordinator.canCollapse = canCollapse
        coordinator.resetToken = resetToken
        return coordinator
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        // Simultaneous recognition with the scroll view's own pan so we keep
        // receiving ticks during the scroll phase (see the delegate below).
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        // Keep *all* coordinator state current — the representable contract
        // expects `update` to refresh everything the persisted coordinator
        // holds. The capability flags gate the handoff direction; the closures
        // capture `ChatOverlay`'s live per-render geometry, so a stale closure
        // would drive the surface from the wrong settled height.
        context.coordinator.canExpand = canExpand
        context.coordinator.canCollapse = canCollapse
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        // The overlay bumped the token on a settle / keyboard toggle: drop any
        // latched per-gesture state so it can't bleed into the next handoff.
        // (Body-drag triggers only fire at rest, so in practice this lands
        // between gestures; clearing here is also a defensive backstop if a
        // future trigger ever flips mid-gesture.)
        if context.coordinator.resetToken != resetToken {
            context.coordinator.resetToken = resetToken
            context.coordinator.reset()
        }
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.handle(recognizer)
    }

    /// Per-gesture state + the `UIGestureRecognizerDelegate` that allows our
    /// pan to run alongside the scroll view's.
    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Forwarding closures, kept current by ``updateUIGestureRecognizer``.
        /// They must be refreshed (not just captured at `makeCoordinator`)
        /// because the call-site closures close over `ChatOverlay`'s live
        /// `metrics` / `keyboardAwareHeight`, which are recomputed each render:
        /// the coordinator persists across renders, so a closure captured once
        /// would feed `updateDrag` stale geometry if the overlay's state
        /// changed (keyboard toggle, expand via the handle) before a drag.
        var onChanged: (CGSize) -> Void
        var onEnded: (CGSize, CGSize) -> Void
        private let arbiter = OverlayDragArbiter()

        /// The inner transcript scroll view, located on `.began` and held
        /// weakly. `nil` in the empty state (no scroll view in the subtree) —
        /// which the arbiter reads as "not scrollable" and drives immediately.
        private weak var scrollView: UIScrollView?
        /// Live expand/collapse capability, refreshed from the representable on
        /// every SwiftUI update. Folded into the arm flags at `.began` so an
        /// up-drag at the bottom doesn't arm expand once fully expanded (and
        /// symmetrically for collapse).
        var canExpand = true
        var canCollapse = true
        /// Last reset token seen from the representable. When the overlay bumps
        /// it (settle / keyboard toggle), ``reset()`` clears the latched state.
        var resetToken = 0

        /// The overlay's signed displacement from its anchor, integrated across
        /// the gesture (see ``OverlayDragArbiter/Step/overlayDisplacement``).
        private var displacement: CGFloat = 0
        /// Cumulative pan translation at the previous tick — subtracted to get
        /// this tick's delta (the integrator's only motion input).
        private var lastTranslationY: CGFloat = 0
        /// `true` once this gesture has driven the overlay at least once. Gates
        /// whether `.ended` fires the snap callback.
        private var didDrive = false
        /// Latched at `.began`: whether a downward / upward drag may engage
        /// resize this gesture (edge-at-start AND remaining capability). Held
        /// constant so scrolling into an edge mid-gesture never engages.
        private var armedCollapse = false
        private var armedExpand = false
        /// The edge this gesture engaged resize from, set on first engagement
        /// and held until `.ended` so the pin stays put across an anchor-
        /// crossing reversal (stay-in-resize). `nil` until engaged.
        private var engagedEdge: OverlayDragArbiter.ScrollEdge?

        init(onChanged: @escaping (CGSize) -> Void, onEnded: @escaping (CGSize, CGSize) -> Void) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        /// Clear every latched per-gesture value. Called at `.began` (fresh
        /// start), at `.ended`/`.cancelled`/`.failed` (tidy teardown), and when
        /// the overlay bumps `resetToken` (settle / keyboard toggle) so no arm /
        /// displacement / engaged-edge state bleeds into the next handoff.
        func reset() {
            displacement = 0
            lastTranslationY = 0
            didDrive = false
            engagedEdge = nil
            armedCollapse = false
            armedExpand = false
        }

        func handle(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                reset()
                scrollView = Self.transcriptScrollView(in: view, at: recognizer.location(in: view))
                // Latch the arm flags from the scroll position at the *start* of
                // the gesture (plus remaining capability). A drag begun
                // mid-content can only ever scroll; one begun at an edge can
                // resize in the matching direction for its whole life.
                let start = scrollState()
                armedCollapse = (start.atTop || !start.isScrollable) && canCollapse
                armedExpand = (start.atBottom || !start.isScrollable) && canExpand

            case .changed:
                let translationY = recognizer.translation(in: view).y
                let deltaY = translationY - lastTranslationY
                lastTranslationY = translationY
                let step = arbiter.step(
                    scroll: scrollState(),
                    deltaY: deltaY,
                    previousDisplacement: displacement,
                    engagedEdge: engagedEdge,
                    armedCollapse: armedCollapse,
                    armedExpand: armedExpand
                )
                displacement = step.overlayDisplacement
                if step.pinScroll {
                    // Record which edge we engaged from on the first driving
                    // tick so the pin (below) stays on that edge even if a
                    // stay-in-resize reversal drives `displacement` back through
                    // the anchor.
                    if engagedEdge == nil {
                        engagedEdge = displacement > 0 ? .top : .bottom
                    }
                    // Counteract the scroll view's own pan for this tick so the
                    // finger drives the overlay, not the content. Re-asserting
                    // the engaged edge's offset every driving tick keeps the
                    // transcript pinned while the overlay resizes.
                    scrollView?.contentOffset.y = step.pinnedOffsetY
                    didDrive = true
                }
                // Once we've driven, keep the overlay synced every tick — even
                // when a reversal carries `displacement` through 0, so the
                // resize tracks the finger continuously to release.
                if didDrive {
                    onChanged(CGSize(width: 0, height: displacement))
                }

            case .ended, .cancelled, .failed:
                if didDrive {
                    let velocityY = recognizer.velocity(in: view).y
                    // Only project momentum when we're still driving on release
                    // (displacement != 0). If the gesture handed back to the
                    // scroll view (displacement == 0), the overlay simply
                    // settles at its anchor — the scroll view keeps its own
                    // deceleration.
                    let projected = displacement != 0
                        ? displacement + overlayDragProjection(velocityY: velocityY)
                        : 0
                    onEnded(
                        CGSize(width: 0, height: displacement),
                        CGSize(width: 0, height: projected)
                    )
                }
                reset()

            default:
                break
            }
        }

        /// Snapshot the tracked scroll view's geometry for the arbiter. Returns
        /// a non-scrollable state when there's no scroll view.
        ///
        /// A `nil` scroll view means one of two things, both handled by the
        /// same "drive immediately" fallback: (1) the empty state, which has no
        /// `ScrollView` under the touch — the intended path; or (2) the
        /// transcript whose `UIScrollView` ``transcriptScrollView(in:at:)``
        /// failed to hit-test. (2) should not happen with today's view tree (the
        /// finger is on the transcript, composited above the backdrop), but if a
        /// future SwiftUI restructure breaks the hit-test, the degradation is
        /// graceful-but-wrong: the transcript stops scrolling and any drag
        /// resizes the overlay. We can't `assert` on nil here because the
        /// empty-state path legitimately hits it; if scrolling ever "feels
        /// broken," suspect this hit-test first.
        private func scrollState() -> OverlayDragArbiter.ScrollState {
            guard let scrollView else {
                return .init(offsetY: 0, topOffsetY: 0, bottomOffsetY: 0, isScrollable: false)
            }
            let inset = scrollView.adjustedContentInset
            let topOffsetY = -inset.top
            let bottomOffsetY = max(
                topOffsetY,
                scrollView.contentSize.height - scrollView.bounds.height + inset.bottom
            )
            return .init(
                offsetY: scrollView.contentOffset.y,
                topOffsetY: topOffsetY,
                bottomOffsetY: bottomOffsetY,
                isScrollable: bottomOffsetY > topOffsetY + OverlayDragArbiter.ScrollState.edgeEpsilon
            )
        }

        /// The transcript scroll view under the drag's start location.
        ///
        /// `UIGestureRecognizerRepresentable` attaches our pan to the app's
        /// *root* hosting view — which also hosts the backdrop applet (e.g. the
        /// Bible reader) behind the chat overlay. A naive depth-first
        /// "first `UIScrollView` in the subtree" walk therefore returned the
        /// **backdrop's** full-screen scroll view (first in subview order),
        /// arming the resize handoff from the wrong scroll position: the chat
        /// would minimize from anywhere and never reach the bottom to expand,
        /// independent of the actual transcript.
        ///
        /// Resolve the transcript's scroll view by *location* instead, in two
        /// steps:
        ///
        /// 1. **Hit-test** the touch point. The frontmost interactive view under
        ///    the finger is the chat transcript (composited above the backdrop),
        ///    so the nearest enclosing scroll view of the hit view is the
        ///    transcript's. This is the precise path and the common case.
        /// 2. **Geometric fallback.** With the keyboard up, the hit-test can
        ///    resolve to non-scrolling chat chrome (the surface background under
        ///    the keyboard-avoidance layout), yielding no enclosing scroll view
        ///    — which the arbiter would misread as "not scrollable" and arm both
        ///    directions, so any drag prematurely resized. So if the hit-test
        ///    finds no scroll view, pick the **frontmost** scroll view whose
        ///    window frame contains the touch (last in front-to-back subview
        ///    order), **excluding any full-window scroll view** — the chat
        ///    transcript is always inset by its own chrome (handle, header,
        ///    composer) so it never fills the window, whereas the backdrop
        ///    applet does. This keeps the fallback off the backdrop both
        ///    mid-transcript and in the empty state (where only the full-window
        ///    backdrop is under the finger, so the fallback finds nothing and
        ///    the caller drives immediately — the intended empty-state path).
        ///
        /// Returns `nil` for the empty state (no inset scroll view under the
        /// touch), which the caller reads as "not scrollable" and drives
        /// immediately.
        static func transcriptScrollView(in view: UIView, at location: CGPoint) -> UIScrollView? {
            if let hit = view.hitTest(location, with: nil),
               let enclosing = enclosingScrollView(of: hit) {
                return enclosing
            }
            let point = view.convert(location, to: nil)
            let windowHeight = view.convert(view.bounds, to: nil).height
            // Collect every scroll view in back-to-front (subview) order with
            // its window frame, then let the pure picker choose the frontmost
            // inset one containing the touch (never the full-window backdrop).
            var scrollViews: [UIScrollView] = []
            var frames: [CGRect] = []
            func walk(_ node: UIView) {
                for subview in node.subviews {
                    if let scrollView = subview as? UIScrollView {
                        scrollViews.append(scrollView)
                        frames.append(scrollView.superview?.convert(scrollView.frame, to: nil) ?? scrollView.frame)
                    }
                    walk(subview)
                }
            }
            walk(view)
            guard let index = frontmostInsetScrollIndex(
                frames: frames, containing: point, windowHeight: windowHeight
            ) else { return nil }
            return scrollViews[index]
        }

        /// The nearest scroll view at or above `view` in the superview chain.
        private static func enclosingScrollView(of view: UIView) -> UIScrollView? {
            var node: UIView? = view
            while let current = node {
                if let scrollView = current as? UIScrollView { return scrollView }
                node = current.superview
            }
            return nil
        }

        // MARK: UIGestureRecognizerDelegate

        /// Allow our pan to recognize alongside the scroll view's pan (and any
        /// other recognizer) — returning `true` from either delegate is enough
        /// to permit simultaneity, which is what lets us observe the scroll
        /// phase before handing off.
        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
#endif
