import SwiftUI

/// Pure decision logic for the content-drag → overlay-drag handoff. Kept free
/// of UIKit so every branch is unit-testable without a device or simulator.
///
/// The chat transcript is a `ScrollView`. We want a single finger-drag on it to
/// scroll the content normally until it reaches an edge, then — in the *same*
/// gesture — take over resizing the chat overlay (drag down past the top edge →
/// collapse/dismiss; drag up past the bottom edge → expand). The arbiter decides,
/// per pan tick, whether the scroll view owns the gesture or the overlay does.
struct OverlayDragArbiter {
    /// What the current pan tick should do.
    enum Phase: Equatable {
        /// Let the inner scroll view consume this tick; the overlay stays put.
        case scrolling
        /// Drive the overlay. `drivenTranslationY` is the pan translation
        /// measured from the handoff point (`0` at the instant of handoff), so
        /// it can be fed straight to the overlay's drag callback as if the drag
        /// had started there — matching what `ChatDragHandle` feeds.
        case drivingPanel(drivenTranslationY: CGFloat)
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

    /// Decide the phase for a single pan tick.
    ///
    /// - Parameters:
    ///   - scroll: live scroll geometry this tick.
    ///   - velocityY: current pan velocity (points/sec); positive = finger
    ///     moving down (revealing content above → scrolling toward the top).
    ///   - canExpand: whether the overlay can still grow (it isn't already at
    ///     the fully-expanded anchor). Gates the up-drag handoff so that, once
    ///     fully expanded, an up-drag scrolls the content instead of fighting a
    ///     no-op expansion.
    ///   - canCollapse: whether the overlay can still shrink (it isn't already
    ///     minimized). Gates the down-drag handoff symmetrically.
    ///   - alreadyDriving: whether an earlier tick in this gesture already
    ///     handed off to the overlay. Once driving, the gesture stays driving
    ///     for its remainder (reversing back into scrolling requires lifting
    ///     the finger — a deliberate v1 simplification).
    ///   - translationY: cumulative pan translation since the gesture began.
    ///   - handoffTranslationY: the translation captured at the handoff tick;
    ///     only meaningful when `alreadyDriving`.
    /// - Returns: `.drivingPanel(drivenTranslationY: 0)` on the tick that first
    ///   hands off (the caller should capture `handoffTranslationY = translationY`
    ///   then), the relative translation on subsequent driving ticks, or
    ///   `.scrolling` while the scroll view still owns the gesture.
    func resolve(
        scroll: ScrollState,
        velocityY: CGFloat,
        canExpand: Bool,
        canCollapse: Bool,
        alreadyDriving: Bool,
        translationY: CGFloat,
        handoffTranslationY: CGFloat
    ) -> Phase {
        if alreadyDriving {
            return .drivingPanel(drivenTranslationY: translationY - handoffTranslationY)
        }
        let draggingDown = velocityY > 0
        let draggingUp = velocityY < 0
        let wantsDrive: Bool
        if !scroll.isScrollable {
            // Empty state / content shorter than the viewport: nothing to
            // scroll, so the overlay drives immediately — in whichever
            // direction it can still move.
            wantsDrive = (draggingDown && canCollapse) || (draggingUp && canExpand)
        } else if draggingDown {
            // Pulling down past the top edge collapses the overlay.
            wantsDrive = scroll.atTop && canCollapse
        } else if draggingUp {
            // Pulling up at *either* scroll edge expands the overlay — mirroring
            // the native sheet's "pull at the edge grows the sheet" feel, and
            // making the up-drag a handoff trigger (not just the down-drag).
            // Mid-content up-drags still scroll toward the bottom edge first;
            // only at an edge (and with room to grow) does the overlay take over.
            wantsDrive = (scroll.atTop || scroll.atBottom) && canExpand
        } else {
            wantsDrive = false
        }
        return wantsDrive ? .drivingPanel(drivenTranslationY: 0) : .scrolling
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
/// handoff a native `.sheet` performs). The decision per tick lives in the pure
/// ``OverlayDragArbiter``; this type only samples live scroll geometry and
/// forwards the result to the overlay's drag callbacks.
struct OverlayContentDragGesture: UIGestureRecognizerRepresentable {
    let onChanged: (CGSize) -> Void
    let onEnded: (CGSize, CGSize) -> Void
    /// Whether the overlay can still grow / shrink from its current settled
    /// anchor. Refreshed onto the coordinator on every SwiftUI update (see
    /// ``updateUIGestureRecognizer``); the arbiter reads them live on each
    /// pre-handoff tick. They equal the *settled* anchor's capability up to the
    /// moment of handoff because the surface hasn't moved yet — the caller
    /// derives them from `progress`, which stays at the settled value until a
    /// drag height is in flight (i.e. until after handoff). So "live read" and
    /// "settled value" coincide exactly where the handoff decision is made.
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
        // Keep the coordinator's expand/collapse capability current. A drag's
        // handoff decision reads these at `.began`, when the overlay is still
        // settled, so they reflect the settled anchor at that moment.
        context.coordinator.canExpand = canExpand
        context.coordinator.canCollapse = canCollapse
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.handle(recognizer)
    }

    /// Per-gesture state + the `UIGestureRecognizerDelegate` that allows our
    /// pan to run alongside the scroll view's.
    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let onChanged: (CGSize) -> Void
        private let onEnded: (CGSize, CGSize) -> Void
        private let arbiter = OverlayDragArbiter()

        /// The inner transcript scroll view, located on `.began` and held
        /// weakly. `nil` in the empty state (no scroll view in the subtree) —
        /// which the arbiter reads as "not scrollable" and drives immediately.
        private weak var scrollView: UIScrollView?
        /// Live expand/collapse capability, refreshed from the representable on
        /// every SwiftUI update. Read at handoff to gate the drag direction so
        /// an up-drag scrolls (rather than no-op expands) once fully expanded.
        var canExpand = true
        var canCollapse = true
        /// `true` once this gesture handed off to driving the overlay.
        private var isDriving = false
        /// Pan translation captured at the handoff tick; subsequent driving
        /// ticks subtract it so the overlay sees a drag that starts at zero.
        private var handoffTranslationY: CGFloat = 0

        init(onChanged: @escaping (CGSize) -> Void, onEnded: @escaping (CGSize, CGSize) -> Void) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        func handle(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                isDriving = false
                handoffTranslationY = 0
                scrollView = Self.findScrollView(in: view)

            case .changed:
                let translationY = recognizer.translation(in: view).y
                let velocityY = recognizer.velocity(in: view).y
                let phase = arbiter.resolve(
                    scroll: scrollState(),
                    velocityY: velocityY,
                    canExpand: canExpand,
                    canCollapse: canCollapse,
                    alreadyDriving: isDriving,
                    translationY: translationY,
                    handoffTranslationY: handoffTranslationY
                )
                switch phase {
                case .scrolling:
                    break
                case .drivingPanel(let driven):
                    if isDriving {
                        onChanged(CGSize(width: 0, height: driven))
                    } else {
                        // First handoff tick: anchor the relative translation
                        // here and stop the scroll view (cleanly cancels its
                        // pan, so it can't also scroll/bounce for the rest of
                        // the gesture).
                        isDriving = true
                        handoffTranslationY = translationY
                        scrollView?.panGestureRecognizer.isEnabled = false
                        onChanged(.zero)
                    }
                }

            case .ended, .cancelled, .failed:
                let wasDriving = isDriving
                let driven = recognizer.translation(in: view).y - handoffTranslationY
                let velocityY = recognizer.velocity(in: view).y
                scrollView?.panGestureRecognizer.isEnabled = true
                isDriving = false
                handoffTranslationY = 0
                if wasDriving {
                    let predicted = driven + overlayDragProjection(velocityY: velocityY)
                    onEnded(
                        CGSize(width: 0, height: driven),
                        CGSize(width: 0, height: predicted)
                    )
                }

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
