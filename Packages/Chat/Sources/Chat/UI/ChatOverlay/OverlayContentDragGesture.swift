import SwiftUI

/// Pure decision logic for the content-drag → overlay-drag handoff. Kept free
/// of UIKit so every branch is unit-testable without a device or simulator.
///
/// The chat transcript is a `ScrollView`. We want a single finger-drag on it to
/// scroll the content normally until it reaches an edge, then — in the *same*
/// gesture — take over resizing the chat overlay. The pairing is edge-specific
/// and symmetric:
///
/// - at the **top** edge, a downward drag **collapses** (minimize);
/// - at the **bottom** edge, an upward drag **expands** (maximize);
/// - mid-content, and at the "wrong" edge for a direction, the scroll view
///   keeps the gesture.
///
/// Crucially the handoff is *reversible within one gesture*: the arbiter is a
/// signed-displacement integrator driven by the per-tick pan **delta**, not a
/// one-shot latch. As long as the overlay is displaced from its anchor it stays
/// in control; the instant the finger reverses far enough to bring the overlay
/// back to its anchor, control returns to the scroll view — so "drag down to
/// minimize, then back up to scroll" flows in a single motion.
struct OverlayDragArbiter {
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
        /// expanding (dragged up from the bottom edge), `0` resting at the
        /// anchor (scroll view owns the gesture). Fed straight to the overlay's
        /// drag callback as a translation — matching what `ChatDragHandle`
        /// feeds (positive height collapses, negative expands).
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
    ///   - scroll: live scroll geometry this tick.
    ///   - deltaY: pan translation change since the previous tick (points);
    ///     positive = finger moving down (scrolling the content toward its top
    ///     edge); negative = finger moving up.
    ///   - previousDisplacement: the overlay's signed displacement carried from
    ///     the previous tick (see ``Step/overlayDisplacement``).
    ///   - canExpand: whether the overlay can still grow (it isn't already at
    ///     the fully-expanded anchor). Gates the *start* of an expand handoff.
    ///   - canCollapse: whether the overlay can still shrink (it isn't already
    ///     minimized). Gates the *start* of a collapse handoff.
    /// - Returns: the integrated ``Step`` for this tick.
    func step(
        scroll: ScrollState,
        deltaY: CGFloat,
        previousDisplacement: CGFloat,
        canExpand: Bool,
        canCollapse: Bool
    ) -> Step {
        // Already displaced toward collapse (driving from the top edge).
        if previousDisplacement > 0 {
            let next = previousDisplacement + deltaY
            // Reversing far enough to reach/pass the anchor hands the gesture
            // back to the scroll view (the leftover up-delta becomes a scroll).
            guard next > 0 else {
                return Step(overlayDisplacement: 0, pinScroll: false, pinnedOffsetY: scroll.topOffsetY)
            }
            return Step(overlayDisplacement: next, pinScroll: true, pinnedOffsetY: scroll.topOffsetY)
        }
        // Already displaced toward expand (driving from the bottom edge).
        if previousDisplacement < 0 {
            let next = previousDisplacement + deltaY
            guard next < 0 else {
                return Step(overlayDisplacement: 0, pinScroll: false, pinnedOffsetY: scroll.bottomOffsetY)
            }
            return Step(overlayDisplacement: next, pinScroll: true, pinnedOffsetY: scroll.bottomOffsetY)
        }

        // Resting at the anchor: the scroll view owns the gesture until it
        // reaches an edge and the finger pushes *past* it.
        let draggingDown = deltaY > 0
        let draggingUp = deltaY < 0

        guard scroll.isScrollable else {
            // Empty state / content shorter than the viewport: nothing to
            // scroll, so the overlay drives immediately — in whichever
            // direction it can still move.
            if draggingDown && canCollapse {
                return Step(overlayDisplacement: deltaY, pinScroll: true, pinnedOffsetY: 0)
            }
            if draggingUp && canExpand {
                return Step(overlayDisplacement: deltaY, pinScroll: true, pinnedOffsetY: 0)
            }
            return Step(overlayDisplacement: 0, pinScroll: false, pinnedOffsetY: 0)
        }

        // At the top, pulling down past the edge collapses the overlay.
        if scroll.atTop && draggingDown && canCollapse {
            return Step(overlayDisplacement: deltaY, pinScroll: true, pinnedOffsetY: scroll.topOffsetY)
        }
        // At the bottom, pulling up past the edge expands the overlay. (An
        // up-drag at the *top* scrolls down through content — it is NOT an
        // expand trigger; expansion only comes from the bottom edge.)
        if scroll.atBottom && draggingUp && canExpand {
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

extension View {
    /// Attach the content-drag → overlay-drag handoff gesture. On UIKit
    /// platforms it wraps a `UIPanGestureRecognizer` that recognizes
    /// simultaneously with the inner scroll view's pan and hands off to the
    /// overlay at the scroll edges; on macOS (no touch / scroll-pan to
    /// coordinate with) it's a no-op so the package still compiles for tests.
    ///
    /// `onChanged` / `onEnded` are the same callbacks `ChatDragHandle` uses —
    /// the overlay can't tell which input drove the drag.
    func overlayContentDrag(
        canExpand: Bool,
        canCollapse: Bool,
        onChanged: @escaping (CGSize) -> Void,
        onEnded: @escaping (CGSize, CGSize) -> Void
    ) -> some View {
        #if canImport(UIKit)
        gesture(
            OverlayContentDragGesture(
                onChanged: onChanged,
                onEnded: onEnded,
                canExpand: canExpand,
                canCollapse: canCollapse
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
/// chat content can scroll the transcript and then hand off to resizing the
/// chat overlay in one continuous motion (the nested-scroll → sheet-drag
/// handoff a native `.sheet` performs). The per-tick integration lives in the
/// pure ``OverlayDragArbiter``; this type only samples live scroll geometry,
/// pins the scroll view while the overlay drives, and forwards the result to
/// the overlay's drag callbacks.
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

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        let coordinator = Coordinator(onChanged: onChanged, onEnded: onEnded)
        coordinator.canExpand = canExpand
        coordinator.canCollapse = canCollapse
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
        /// every SwiftUI update. Read when at the anchor to gate the *start* of
        /// a handoff so an up-drag at the bottom doesn't no-op-expand once
        /// fully expanded (and symmetrically for collapse).
        var canExpand = true
        var canCollapse = true

        /// The overlay's signed displacement from its anchor, integrated across
        /// the gesture (see ``OverlayDragArbiter/Step/overlayDisplacement``).
        private var displacement: CGFloat = 0
        /// Cumulative pan translation at the previous tick — subtracted to get
        /// this tick's delta (the integrator's only motion input).
        private var lastTranslationY: CGFloat = 0
        /// `true` once this gesture has driven the overlay at least once. Gates
        /// whether `.ended` fires the snap callback and whether we keep syncing
        /// the overlay back to its anchor after a reversal.
        private var didDrive = false

        init(onChanged: @escaping (CGSize) -> Void, onEnded: @escaping (CGSize, CGSize) -> Void) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        func handle(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                displacement = 0
                lastTranslationY = 0
                didDrive = false
                scrollView = Self.findScrollView(in: view)

            case .changed:
                let translationY = recognizer.translation(in: view).y
                let deltaY = translationY - lastTranslationY
                lastTranslationY = translationY
                let step = arbiter.step(
                    scroll: scrollState(),
                    deltaY: deltaY,
                    previousDisplacement: displacement,
                    canExpand: canExpand,
                    canCollapse: canCollapse
                )
                displacement = step.overlayDisplacement
                if step.pinScroll {
                    // Counteract the scroll view's own pan for this tick so the
                    // finger drives the overlay, not the content. Re-asserting
                    // the edge offset every driving tick (rather than disabling
                    // the scroll view's pan) is what keeps the handoff
                    // reversible: the moment we stop pinning, the still-enabled
                    // scroll pan resumes scrolling from the pinned edge.
                    scrollView?.contentOffset.y = step.pinnedOffsetY
                    didDrive = true
                }
                // Once we've driven, keep the overlay synced every tick —
                // including the tick that returns it to the anchor (`displacement
                // == 0`) so a reversal visibly hands back rather than freezing.
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
                displacement = 0
                lastTranslationY = 0
                didDrive = false

            default:
                break
            }
        }

        /// Snapshot the tracked scroll view's geometry for the arbiter. Returns
        /// a non-scrollable state when there's no scroll view.
        ///
        /// A `nil` scroll view means one of two things, both handled by the
        /// same "drive immediately" fallback: (1) the empty state, which has no
        /// `ScrollView` at all — the intended path; or (2) the transcript whose
        /// `UIScrollView` ``findScrollView(in:)`` failed to locate. (2) should
        /// not happen with today's view tree (the gesture is on the content
        /// host whose descendant is `MessageList`'s scroll view), but if a
        /// future SwiftUI restructure breaks the walk, the degradation is
        /// graceful-but-wrong: the transcript stops scrolling and any drag
        /// resizes the overlay. We can't `assert` on nil here because the
        /// empty-state path legitimately hits it; if scrolling ever "feels
        /// broken," suspect this walk first.
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

        /// First `UIScrollView` in `view`'s subtree (depth-first). The gesture
        /// is attached to the content host whose descendant is the transcript's
        /// scroll view.
        static func findScrollView(in view: UIView) -> UIScrollView? {
            for subview in view.subviews {
                if let scrollView = subview as? UIScrollView { return scrollView }
                if let found = findScrollView(in: subview) { return found }
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
