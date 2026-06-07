import Foundation
import Testing
@testable import Chat

/// Tests for `OverlayDragArbiter` — the pure per-tick integrator behind the
/// content-drag → overlay-drag handoff — and the `overlayDragProjection` flick
/// helper. Resolves in-process with no UIKit, so the handoff rules are pinned
/// without a device or simulator.
///
/// The model is **arm-at-start, stay-in-resize**: the coordinator latches
/// `armedCollapse` / `armedExpand` at `.began` from where the scroll sat (and
/// the overlay's remaining capability), and these stay constant for the whole
/// gesture. While not engaged (`engagedEdge == nil`) a drag only resizes if it
/// was armed in that direction — scrolling *into* an edge mid-gesture never
/// engages, because the flags reflect the start, not the live edge. Once
/// engaged, `engagedEdge` is set and the gesture stays in resize until release,
/// pinning that edge even through an anchor-crossing reversal.
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

    // MARK: - Not armed (began mid-content): the scroll view owns the gesture

    @Test("Not armed, a down-drag lets the scroll view own the gesture")
    func notArmedDownScrolls() {
        let step = arbiter.step(
            scroll: midContent(), deltaY: 12, previousDisplacement: 0,
            engagedEdge: nil, armedCollapse: false, armedExpand: false
        )
        #expect(step.overlayDisplacement == 0)
        #expect(step.pinScroll == false)
    }

    @Test("Not armed, an up-drag lets the scroll view own the gesture")
    func notArmedUpScrolls() {
        let step = arbiter.step(
            scroll: midContent(), deltaY: -12, previousDisplacement: 0,
            engagedEdge: nil, armedCollapse: false, armedExpand: false
        )
        #expect(step.overlayDisplacement == 0)
        #expect(step.pinScroll == false)
    }

    @Test("Arm flags are latched at start: scrolling INTO the top edge mid-gesture never collapses")
    func latchedFlagsIgnoreLiveEdge() {
        // The core of the rework: even though the live scroll now reads `atTop`,
        // a gesture that began mid-content (armedCollapse == false) keeps
        // scrolling on a down-drag — it does not engage collapse.
        let step = arbiter.step(
            scroll: atTop(), deltaY: 12, previousDisplacement: 0,
            engagedEdge: nil, armedCollapse: false, armedExpand: false
        )
        #expect(step.overlayDisplacement == 0)
        #expect(step.pinScroll == false)
    }

    @Test("Arm flags are latched at start: scrolling INTO the bottom edge mid-gesture never expands")
    func latchedFlagsIgnoreLiveBottomEdge() {
        let step = arbiter.step(
            scroll: atBottom(), deltaY: -12, previousDisplacement: 0,
            engagedEdge: nil, armedCollapse: false, armedExpand: false
        )
        #expect(step.overlayDisplacement == 0)
        #expect(step.pinScroll == false)
    }

    // MARK: - Engaging (armed at the matching edge)

    @Test("Armed to collapse, a down-drag engages and pins the top edge")
    func armedCollapseDownEngages() {
        let step = arbiter.step(
            scroll: atTop(), deltaY: 12, previousDisplacement: 0,
            engagedEdge: nil, armedCollapse: true, armedExpand: false
        )
        #expect(step.overlayDisplacement == 12)
        #expect(step.pinScroll)
        #expect(step.pinnedOffsetY == 0)
    }

    @Test("Armed to expand, an up-drag engages and pins the bottom edge")
    func armedExpandUpEngages() {
        let step = arbiter.step(
            scroll: atBottom(), deltaY: -12, previousDisplacement: 0,
            engagedEdge: nil, armedCollapse: false, armedExpand: true
        )
        #expect(step.overlayDisplacement == -12)
        #expect(step.pinScroll)
        #expect(step.pinnedOffsetY == 1000)
    }

    @Test("Armed to collapse only, an up-drag still scrolls (collapse is a down-drag)")
    func armedCollapseUpScrolls() {
        // At the top, a finger moving up has nowhere to scroll and must not
        // expand — expansion only arms at the bottom.
        let step = arbiter.step(
            scroll: atTop(), deltaY: -12, previousDisplacement: 0,
            engagedEdge: nil, armedCollapse: true, armedExpand: false
        )
        #expect(step.overlayDisplacement == 0)
        #expect(step.pinScroll == false)
    }

    @Test("Armed to expand only, a down-drag still scrolls (expand is an up-drag)")
    func armedExpandDownScrolls() {
        let step = arbiter.step(
            scroll: atBottom(), deltaY: 12, previousDisplacement: 0,
            engagedEdge: nil, armedCollapse: false, armedExpand: true
        )
        #expect(step.overlayDisplacement == 0)
        #expect(step.pinScroll == false)
    }

    @Test("A directionless tick (zero delta) never engages, even when armed both ways")
    func zeroDeltaDoesNotEngage() {
        let step = arbiter.step(
            scroll: atTop(), deltaY: 0, previousDisplacement: 0,
            engagedEdge: nil, armedCollapse: true, armedExpand: true
        )
        #expect(step.overlayDisplacement == 0)
        #expect(step.pinScroll == false)
    }

    // MARK: - Stay in resize (engaged, no hand-back)

    @Test("Engaged from the top, a further down-delta keeps driving and stays pinned")
    func engagedTopContinues() {
        let step = arbiter.step(
            scroll: atTop(), deltaY: 10, previousDisplacement: 30,
            engagedEdge: .top, armedCollapse: true, armedExpand: false
        )
        #expect(step.overlayDisplacement == 40)
        #expect(step.pinScroll)
        #expect(step.pinnedOffsetY == 0)
    }

    @Test("Engaged from the top, reversing up shrinks the displacement but stays engaged")
    func engagedTopReversesButStaysEngaged() {
        let step = arbiter.step(
            scroll: atTop(), deltaY: -10, previousDisplacement: 30,
            engagedEdge: .top, armedCollapse: true, armedExpand: false
        )
        #expect(step.overlayDisplacement == 20)
        #expect(step.pinScroll)
    }

    @Test("Engaged from the top, reversing PAST the anchor stays in resize (no hand-back, no edge flip)")
    func engagedTopReversesThroughAnchor() {
        // Replaces the old reversible "releases at anchor" behavior: under
        // stay-in-resize the drag keeps driving (displacement goes negative)
        // and keeps pinning the *top* edge it engaged from — it does NOT hand
        // back to the scroll view, nor flip to pinning the bottom edge.
        let step = arbiter.step(
            scroll: atTop(), deltaY: -20, previousDisplacement: 8,
            engagedEdge: .top, armedCollapse: true, armedExpand: false
        )
        #expect(step.overlayDisplacement == -12)
        #expect(step.pinScroll)
        #expect(step.pinnedOffsetY == 0)
    }

    @Test("Engaged from the bottom, a further up-delta keeps driving and stays pinned")
    func engagedBottomContinues() {
        let step = arbiter.step(
            scroll: atBottom(), deltaY: -10, previousDisplacement: -30,
            engagedEdge: .bottom, armedCollapse: false, armedExpand: true
        )
        #expect(step.overlayDisplacement == -40)
        #expect(step.pinScroll)
        #expect(step.pinnedOffsetY == 1000)
    }

    @Test("Engaged from the bottom, reversing down past the anchor stays in resize (no flip)")
    func engagedBottomReversesThroughAnchor() {
        let step = arbiter.step(
            scroll: atBottom(), deltaY: 20, previousDisplacement: -8,
            engagedEdge: .bottom, armedCollapse: false, armedExpand: true
        )
        #expect(step.overlayDisplacement == 12)
        #expect(step.pinScroll)
        #expect(step.pinnedOffsetY == 1000)
    }

    // MARK: - Capability folded into the arm flags

    @Test("Already fully expanded (expand not armed), an up-drag scrolls instead of expanding")
    func notArmedExpandUpScrolls() {
        // The coordinator computes `armedExpand = atBottom && canExpand`; fully
        // expanded means canExpand == false, so the flag is false here.
        let step = arbiter.step(
            scroll: atBottom(), deltaY: -12, previousDisplacement: 0,
            engagedEdge: nil, armedCollapse: false, armedExpand: false
        )
        #expect(step.overlayDisplacement == 0)
        #expect(step.pinScroll == false)
    }

    @Test("Already minimized (collapse not armed), a down-drag scrolls instead of collapsing")
    func notArmedCollapseDownScrolls() {
        let step = arbiter.step(
            scroll: atTop(), deltaY: 12, previousDisplacement: 0,
            engagedEdge: nil, armedCollapse: false, armedExpand: false
        )
        #expect(step.overlayDisplacement == 0)
        #expect(step.pinScroll == false)
    }

    // MARK: - Non-scrollable (empty / short content)

    @Test("Non-scrollable content armed both ways drives in whichever direction the finger moves")
    func nonScrollableArmedDrivesImmediately() {
        // For non-scrollable content the coordinator arms both directions (up to
        // capability); the arbiter then engages on the first directional tick.
        let nonScrollable = OverlayDragArbiter.ScrollState(
            offsetY: 0, topOffsetY: 0, bottomOffsetY: 0, isScrollable: false
        )
        let down = arbiter.step(
            scroll: nonScrollable, deltaY: 12, previousDisplacement: 0,
            engagedEdge: nil, armedCollapse: true, armedExpand: true
        )
        let up = arbiter.step(
            scroll: nonScrollable, deltaY: -12, previousDisplacement: 0,
            engagedEdge: nil, armedCollapse: true, armedExpand: true
        )
        #expect(down.overlayDisplacement == 12)
        #expect(down.pinScroll)
        #expect(up.overlayDisplacement == -12)
        #expect(up.pinScroll)
    }

    // MARK: - ScrollState edge helpers (read by the coordinator at .began)

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
