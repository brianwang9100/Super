import Foundation
import Testing
@testable import Chat

/// Tests for `OverlayDragArbiter` — the pure per-tick decision behind the
/// content-drag → overlay-drag handoff (scroll the transcript until an edge,
/// then resize the overlay in the same gesture) — and the `overlayDragProjection`
/// flick helper. Resolves in-process with no UIKit, so the handoff rules are
/// pinned without a device or simulator.
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

    // MARK: - Scroll phase

    @Test("Mid-content drag lets the scroll view own the gesture")
    func midContentScrolls() {
        let phase = arbiter.resolve(
            scroll: midContent(),
            velocityY: 400,
            canExpand: true,
            canCollapse: true,
            alreadyDriving: false,
            translationY: 60,
            handoffTranslationY: 0
        )
        #expect(phase == .scrolling)
    }

    @Test("Mid-content up-drag scrolls toward the bottom (not an expand handoff)")
    func midContentUpScrolls() {
        let phase = arbiter.resolve(
            scroll: midContent(),
            velocityY: -400,
            canExpand: true,
            canCollapse: true,
            alreadyDriving: false,
            translationY: -60,
            handoffTranslationY: 0
        )
        #expect(phase == .scrolling)
    }

    @Test("At the bottom, dragging down (into content) keeps scrolling")
    func atBottomDraggingDownScrolls() {
        let phase = arbiter.resolve(
            scroll: atBottom(),
            velocityY: 500,
            canExpand: true,
            canCollapse: true,
            alreadyDriving: false,
            translationY: 40,
            handoffTranslationY: 0
        )
        #expect(phase == .scrolling)
    }

    // MARK: - Handoff

    @Test("At the top, dragging down hands off to collapse")
    func atTopDraggingDownHandsOff() {
        let phase = arbiter.resolve(
            scroll: atTop(),
            velocityY: 500,
            canExpand: true,
            canCollapse: true,
            alreadyDriving: false,
            translationY: 80,
            handoffTranslationY: 0
        )
        #expect(phase == .drivingPanel(drivenTranslationY: 0))
    }

    @Test("At the top, dragging up now hands off to expand (the new trigger)")
    func atTopDraggingUpHandsOffToExpand() {
        let phase = arbiter.resolve(
            scroll: atTop(),
            velocityY: -500,
            canExpand: true,
            canCollapse: true,
            alreadyDriving: false,
            translationY: -40,
            handoffTranslationY: 0
        )
        #expect(phase == .drivingPanel(drivenTranslationY: 0))
    }

    @Test("At the bottom, dragging up hands off to expand")
    func atBottomDraggingUpHandsOff() {
        let phase = arbiter.resolve(
            scroll: atBottom(),
            velocityY: -500,
            canExpand: true,
            canCollapse: true,
            alreadyDriving: false,
            translationY: -80,
            handoffTranslationY: 0
        )
        #expect(phase == .drivingPanel(drivenTranslationY: 0))
    }

    // MARK: - Capability gating

    @Test("Already fully expanded, an up-drag at the top scrolls instead of expanding")
    func fullyExpandedTopUpScrolls() {
        let phase = arbiter.resolve(
            scroll: atTop(),
            velocityY: -500,
            canExpand: false,
            canCollapse: true,
            alreadyDriving: false,
            translationY: -40,
            handoffTranslationY: 0
        )
        #expect(phase == .scrolling)
    }

    @Test("Already minimized, a down-drag at the top scrolls instead of collapsing")
    func fullyMinimizedTopDownScrolls() {
        let phase = arbiter.resolve(
            scroll: atTop(),
            velocityY: 500,
            canExpand: true,
            canCollapse: false,
            alreadyDriving: false,
            translationY: 40,
            handoffTranslationY: 0
        )
        #expect(phase == .scrolling)
    }

    @Test("Non-scrollable content drives in whichever direction the overlay can move")
    func nonScrollableDrivesImmediately() {
        let nonScrollable = OverlayDragArbiter.ScrollState(
            offsetY: 0, topOffsetY: 0, bottomOffsetY: 0, isScrollable: false
        )
        let down = arbiter.resolve(
            scroll: nonScrollable, velocityY: 300, canExpand: true, canCollapse: true,
            alreadyDriving: false, translationY: 30, handoffTranslationY: 0
        )
        let up = arbiter.resolve(
            scroll: nonScrollable, velocityY: -300, canExpand: true, canCollapse: true,
            alreadyDriving: false, translationY: -30, handoffTranslationY: 0
        )
        #expect(down == .drivingPanel(drivenTranslationY: 0))
        #expect(up == .drivingPanel(drivenTranslationY: 0))
    }

    @Test("Non-scrollable content won't drive past an anchor it can't move toward")
    func nonScrollableRespectsCapability() {
        let nonScrollable = OverlayDragArbiter.ScrollState(
            offsetY: 0, topOffsetY: 0, bottomOffsetY: 0, isScrollable: false
        )
        // Fully expanded: an up-drag has nowhere to grow → no handoff.
        let up = arbiter.resolve(
            scroll: nonScrollable, velocityY: -300, canExpand: false, canCollapse: true,
            alreadyDriving: false, translationY: -30, handoffTranslationY: 0
        )
        #expect(up == .scrolling)
    }

    @Test("A directionless tick (zero velocity) at the top doesn't hand off")
    func zeroVelocityAtTopScrolls() {
        // The handoff direction is decided by velocity sign; a momentary
        // zero-velocity sample (e.g. a hold at the edge) stays with the scroll
        // view until the finger commits to a direction.
        let phase = arbiter.resolve(
            scroll: atTop(),
            velocityY: 0,
            canExpand: true,
            canCollapse: true,
            alreadyDriving: false,
            translationY: 0,
            handoffTranslationY: 0
        )
        #expect(phase == .scrolling)
    }

    // MARK: - Stay-driving after handoff

    @Test("Once driving, subsequent ticks report translation relative to the handoff")
    func drivingReportsRelativeTranslation() {
        // Handed off at translationY = 80; now at 200 → overlay sees 120.
        let phase = arbiter.resolve(
            scroll: atTop(),
            velocityY: 600,
            canExpand: true,
            canCollapse: true,
            alreadyDriving: true,
            translationY: 200,
            handoffTranslationY: 80
        )
        #expect(phase == .drivingPanel(drivenTranslationY: 120))
    }

    @Test("Once driving, reversing direction keeps driving (no return to scroll)")
    func drivingStaysDrivingOnReverse() {
        // Reversing back toward (and past) the handoff point still drives —
        // the overlay returns to its anchor rather than the scroll view
        // re-claiming the gesture mid-drag.
        let phase = arbiter.resolve(
            scroll: atTop(),
            velocityY: -800,
            canExpand: true,
            canCollapse: true,
            alreadyDriving: true,
            translationY: 40,
            handoffTranslationY: 80
        )
        #expect(phase == .drivingPanel(drivenTranslationY: -40))
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
