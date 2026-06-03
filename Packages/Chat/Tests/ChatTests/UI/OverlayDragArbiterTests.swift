import Foundation
import Testing
@testable import Chat

/// Tests for `OverlayDragArbiter` — the pure per-tick integrator behind the
/// content-drag → overlay-drag handoff (scroll the transcript until an edge,
/// then resize the overlay in the *same* gesture, reversibly) — and the
/// `overlayDragProjection` flick helper. Resolves in-process with no UIKit, so
/// the handoff rules are pinned without a device or simulator.
///
/// The model is a signed-displacement integrator: each tick takes the per-tick
/// pan *delta* and the overlay's current displacement from its settled anchor
/// (`> 0` collapsing from the top edge, `< 0` expanding from the bottom edge,
/// `0` at the anchor) and returns the new displacement plus whether the inner
/// scroll view must be pinned this tick. Because every tick is recomputed from
/// the live edge + delta, reversing the finger hands control straight back to
/// the scroll view — no latch.
@Suite("OverlayDragArbiter handoff")
struct OverlayDragArbiterTests {
    private let arbiter = OverlayDragArbiter()

    /// A scrollable state parked mid-content (neither edge).
    private func midContent() -> OverlayDragArbiter.ScrollState {
        .init(offsetY: 200, topOffsetY: 0, bottomOffsetY: 1000, isScrollable: true)
    }

    private func atTop() -> OverlayDragArbiter.ScrollState {
        .init(offsetY: 0, topOffsetY: 0, bottomOffsetY: 1000, isScrollable: true)
    }

    private func atBottom() -> OverlayDragArbiter.ScrollState {
        .init(offsetY: 1000, topOffsetY: 0, bottomOffsetY: 1000, isScrollable: true)
    }

    // MARK: - Scroll phase (at the anchor, scroll owns the gesture)

    @Test("Mid-content down-drag lets the scroll view own the gesture")
    func midContentDownScrolls() {
        let step = arbiter.step(
            scroll: midContent(), deltaY: 12, previousDisplacement: 0,
            canExpand: true, canCollapse: true
        )
        #expect(step.overlayDisplacement == 0)
        #expect(step.pinScroll == false)
    }

    @Test("Mid-content up-drag scrolls toward the bottom (not an expand handoff)")
    func midContentUpScrolls() {
        let step = arbiter.step(
            scroll: midContent(), deltaY: -12, previousDisplacement: 0,
            canExpand: true, canCollapse: true
        )
        #expect(step.overlayDisplacement == 0)
        #expect(step.pinScroll == false)
    }

    @Test("At the bottom, dragging down (into content) keeps scrolling")
    func atBottomDraggingDownScrolls() {
        let step = arbiter.step(
            scroll: atBottom(), deltaY: 12, previousDisplacement: 0,
            canExpand: true, canCollapse: true
        )
        #expect(step.overlayDisplacement == 0)
        #expect(step.pinScroll == false)
    }

    @Test("At the top, dragging up scrolls down through content (NOT an expand)")
    func atTopDraggingUpScrolls() {
        // The defect this replaces: an up-drag at the top used to expand the
        // overlay. The overlay only maximizes from the *bottom* edge.
        let step = arbiter.step(
            scroll: atTop(), deltaY: -12, previousDisplacement: 0,
            canExpand: true, canCollapse: true
        )
        #expect(step.overlayDisplacement == 0)
        #expect(step.pinScroll == false)
    }

    // MARK: - Handoff (edge + direction specific)

    @Test("At the top, dragging down hands off to collapse and pins the scroll view")
    func atTopDraggingDownCollapses() {
        let step = arbiter.step(
            scroll: atTop(), deltaY: 12, previousDisplacement: 0,
            canExpand: true, canCollapse: true
        )
        #expect(step.overlayDisplacement == 12)
        #expect(step.pinScroll)
        #expect(step.pinnedOffsetY == 0)
    }

    @Test("At the bottom, dragging up hands off to expand and pins the scroll view")
    func atBottomDraggingUpExpands() {
        let step = arbiter.step(
            scroll: atBottom(), deltaY: -12, previousDisplacement: 0,
            canExpand: true, canCollapse: true
        )
        #expect(step.overlayDisplacement == -12)
        #expect(step.pinScroll)
        #expect(step.pinnedOffsetY == 1000)
    }

    // MARK: - Reversible handoff (no latch)

    @Test("While collapsing, a further down-delta keeps driving and stays pinned")
    func collapsingContinues() {
        let step = arbiter.step(
            scroll: atTop(), deltaY: 10, previousDisplacement: 30,
            canExpand: true, canCollapse: true
        )
        #expect(step.overlayDisplacement == 40)
        #expect(step.pinScroll)
    }

    @Test("While collapsing, reversing up shrinks the displacement back toward the anchor")
    func collapsingReverses() {
        let step = arbiter.step(
            scroll: atTop(), deltaY: -10, previousDisplacement: 30,
            canExpand: true, canCollapse: true
        )
        #expect(step.overlayDisplacement == 20)
        #expect(step.pinScroll)
    }

    @Test("Reversing past the anchor releases the gesture back to the scroll view")
    func collapsingReleasesAtAnchor() {
        // Displacement 8, finger reverses up by 20 → would cross the anchor.
        // The overlay returns to its anchor (0) and the scroll view takes over
        // again — the "transition straight into a scroll within the same drag".
        let step = arbiter.step(
            scroll: atTop(), deltaY: -20, previousDisplacement: 8,
            canExpand: true, canCollapse: true
        )
        #expect(step.overlayDisplacement == 0)
        #expect(step.pinScroll == false)
    }

    @Test("While expanding, reversing down past the anchor releases to the scroll view")
    func expandingReleasesAtAnchor() {
        let step = arbiter.step(
            scroll: atBottom(), deltaY: 20, previousDisplacement: -8,
            canExpand: true, canCollapse: true
        )
        #expect(step.overlayDisplacement == 0)
        #expect(step.pinScroll == false)
    }

    @Test("While expanding, a further up-delta keeps driving and stays pinned")
    func expandingContinues() {
        let step = arbiter.step(
            scroll: atBottom(), deltaY: -10, previousDisplacement: -30,
            canExpand: true, canCollapse: true
        )
        #expect(step.overlayDisplacement == -40)
        #expect(step.pinScroll)
    }

    // MARK: - Capability gating

    @Test("Already fully expanded, an up-drag at the bottom scrolls instead of expanding")
    func fullyExpandedBottomUpScrolls() {
        let step = arbiter.step(
            scroll: atBottom(), deltaY: -12, previousDisplacement: 0,
            canExpand: false, canCollapse: true
        )
        #expect(step.overlayDisplacement == 0)
        #expect(step.pinScroll == false)
    }

    @Test("Already minimized, a down-drag at the top scrolls instead of collapsing")
    func fullyMinimizedTopDownScrolls() {
        let step = arbiter.step(
            scroll: atTop(), deltaY: 12, previousDisplacement: 0,
            canExpand: true, canCollapse: false
        )
        #expect(step.overlayDisplacement == 0)
        #expect(step.pinScroll == false)
    }

    // MARK: - Non-scrollable (empty state)

    @Test("Non-scrollable content drives in whichever direction the overlay can move")
    func nonScrollableDrivesImmediately() {
        let nonScrollable = OverlayDragArbiter.ScrollState(
            offsetY: 0, topOffsetY: 0, bottomOffsetY: 0, isScrollable: false
        )
        let down = arbiter.step(
            scroll: nonScrollable, deltaY: 12, previousDisplacement: 0,
            canExpand: true, canCollapse: true
        )
        let up = arbiter.step(
            scroll: nonScrollable, deltaY: -12, previousDisplacement: 0,
            canExpand: true, canCollapse: true
        )
        #expect(down.overlayDisplacement == 12)
        #expect(down.pinScroll)
        #expect(up.overlayDisplacement == -12)
        #expect(up.pinScroll)
    }

    @Test("Non-scrollable content won't drive past an anchor it can't move toward")
    func nonScrollableRespectsCapability() {
        let nonScrollable = OverlayDragArbiter.ScrollState(
            offsetY: 0, topOffsetY: 0, bottomOffsetY: 0, isScrollable: false
        )
        // Fully expanded: an up-drag has nowhere to grow → no handoff.
        let up = arbiter.step(
            scroll: nonScrollable, deltaY: -12, previousDisplacement: 0,
            canExpand: false, canCollapse: true
        )
        #expect(up.overlayDisplacement == 0)
        #expect(up.pinScroll == false)
    }

    @Test("A directionless tick (zero delta) at the top doesn't hand off")
    func zeroDeltaAtTopScrolls() {
        let step = arbiter.step(
            scroll: atTop(), deltaY: 0, previousDisplacement: 0,
            canExpand: true, canCollapse: true
        )
        #expect(step.overlayDisplacement == 0)
        #expect(step.pinScroll == false)
    }

    // MARK: - ScrollState edge helpers

    @Test("atTop / atBottom honor the edge epsilon")
    func edgeEpsilonTolerance() {
        let nearTop = OverlayDragArbiter.ScrollState(
            offsetY: 0.4, topOffsetY: 0, bottomOffsetY: 1000, isScrollable: true
        )
        let nearBottom = OverlayDragArbiter.ScrollState(
            offsetY: 999.6, topOffsetY: 0, bottomOffsetY: 1000, isScrollable: true
        )
        #expect(nearTop.atTop)
        #expect(nearBottom.atBottom)
    }

    // MARK: - Flick projection

    @Test("Projection sign follows the flick direction")
    func projectionSign() {
        #expect(overlayDragProjection(velocityY: 1000) > 0)
        #expect(overlayDragProjection(velocityY: -1000) < 0)
        #expect(overlayDragProjection(velocityY: 0) == 0)
    }

    @Test("A hard downward flick projects past the snap's skip-velocity threshold")
    func hardFlickExceedsSkipVelocity() {
        // `ChatOverlay.endDrag` computes velocity = predicted - translation =
        // overlayDragProjection(velocityY); a hard flick must clear
        // `ChatPresentationState.skipVelocity` (1200) so it snaps to the
        // endpoint anchor rather than the nearest one.
        let projected = overlayDragProjection(velocityY: 3000)
        #expect(projected > ChatPresentationState.skipVelocity)
    }

    @Test("A gentle drag-end stays below the skip-velocity threshold")
    func gentleReleaseStaysBelowSkipVelocity() {
        let projected = overlayDragProjection(velocityY: 800)
        #expect(abs(projected) < ChatPresentationState.skipVelocity)
    }
}
