import Foundation
import Testing
@testable import Chat

/// Tests for `ChatPresentationState`'s anchor-height resolution, nearest-
/// anchor selection on drag release, and the velocity-biased `snapTarget`
/// the chat overlay uses to settle after a drag. Pure-logic unit tests
/// (no view rendering) — keeps fast feedback on snap behavior so race-y
/// snapshot suites don't have to gate it.
@Suite("ChatPresentationState anchors")
struct ChatPresentationStateTests {
    private let viewport: CGFloat = 874

    @Test("expanded anchor fills the container")
    func expandedHeightFillsContainer() {
        let h = ChatPresentationState.expanded.height(in: viewport)
        #expect(h == viewport)
    }

    @Test("semi-expanded anchor reserves `topInset` from the container")
    func semiExpandedHeightReservesTopInset() {
        // With a 100pt top inset (e.g. ~48pt safe area + 52pt chrome
        // reserve) the semi anchor leaves exactly that much room above
        // for the backdrop applet's nav bar — handle lands at y=100.
        let h = ChatPresentationState.semiExpanded.height(in: viewport, topInset: 100)
        #expect(h == viewport - 100)
    }

    @Test("semi-expanded anchor falls back to the container with zero top inset")
    func semiExpandedHeightWithNoTopInset() {
        // `topInset = 0` is the default — meaningful only as a "no chrome
        // to avoid" case (every production caller threads in a non-zero
        // value via ``ChatOverlayMetrics``); the anchor's height collapses
        // to the container itself, the floor still wins under it.
        let h = ChatPresentationState.semiExpanded.height(in: viewport)
        #expect(h == viewport)
    }

    @Test("semi-expanded anchor enforces a floor on small viewports")
    func semiExpandedHeightFloorOnSmallViewports() {
        // 300pt − 100pt topInset = 200pt — below the 280pt floor.
        let h = ChatPresentationState.semiExpanded.height(in: 300, topInset: 100)
        #expect(h == ChatPresentationState.semiExpandedMinHeight)
    }

    @Test("minimized anchor adds the bottom safe-area inset to the base height")
    func minimizedAddsSafeArea() {
        let h = ChatPresentationState.minimized.height(in: viewport, bottomSafeArea: 34)
        #expect(h == ChatPresentationState.minimizedBaseHeight + 34)
    }

    // MARK: - Nearest anchor

    @Test("a release near the minimized height snaps to minimized")
    func nearestAtMinimized() {
        let nearest = ChatPresentationState.nearestAnchor(forHeight: 70, in: viewport)
        #expect(nearest == .minimized)
    }

    @Test("a release near the semi-expanded height snaps to semi-expanded")
    func nearestAtSemi() {
        // Match `ChatOverlayMetrics`'s topInset shape (safe area + 52pt
        // chrome reserve) so the snap envelope sees the same anchor the
        // user dragged against.
        let topInset: CGFloat = 88
        let target = ChatPresentationState.semiExpanded.height(in: viewport, topInset: topInset)
        let nearest = ChatPresentationState.nearestAnchor(
            forHeight: target + 30,
            in: viewport,
            topInset: topInset
        )
        #expect(nearest == .semiExpanded)
    }

    @Test("a release in the band below the new semi anchor still snaps to semi")
    func semiSnapDominatesAroundNewAnchor() {
        // Regression guard against the upgrade from the legacy 0.52
        // ratio anchor (~454pt on a 874pt viewport) to the new
        // `containerH - topInset` anchor (~786pt). A release at 730pt
        // sits between the legacy and new semi heights; without
        // threading `topInset` through `nearestAnchor`, the snap would
        // have picked `.expanded` (closer to 874 than to 454).
        let topInset: CGFloat = 88
        let nearest = ChatPresentationState.nearestAnchor(
            forHeight: 730,
            in: viewport,
            topInset: topInset
        )
        #expect(nearest == .semiExpanded)
    }

    @Test("a release near the full viewport snaps to expanded")
    func nearestAtExpanded() {
        let nearest = ChatPresentationState.nearestAnchor(forHeight: viewport - 20, in: viewport)
        #expect(nearest == .expanded)
    }

    // MARK: - Snap with velocity

    @Test("a hard downward flick jumps to minimized regardless of height")
    func hardDownwardFlickJumpsToMinimized() {
        let target = ChatPresentationState.snapTarget(
            currentHeight: viewport - 40, // basically expanded
            velocity: ChatPresentationState.skipVelocity + 100, // downward = collapsing
            containerHeight: viewport
        )
        #expect(target == .minimized)
    }

    @Test("a hard upward flick jumps to expanded regardless of height")
    func hardUpwardFlickJumpsToExpanded() {
        let target = ChatPresentationState.snapTarget(
            currentHeight: 80, // basically minimized
            velocity: -(ChatPresentationState.skipVelocity + 100), // upward = expanding
            containerHeight: viewport
        )
        #expect(target == .expanded)
    }

    @Test("a slow release projects forward by velocity and snaps to nearest")
    func slowReleaseProjectsThenSnaps() {
        // The release height (300) is geometrically closer to semi-expanded
        // (≈454) than to minimized (60). A bare nearest-anchor lookup would
        // therefore pick semi. A downward predicted-end of 250pt projects
        // the height to 50, which snaps to minimized — proving the snap
        // actually uses velocity, not just position.
        let target = ChatPresentationState.snapTarget(
            currentHeight: 300,
            velocity: 250, // collapsing, below skip threshold
            containerHeight: viewport
        )
        #expect(target == .minimized)
    }

    @Test("a stationary release picks the nearest anchor without bias")
    func stationaryReleasePicksNearest() {
        let topInset: CGFloat = 88
        let semiHeight = ChatPresentationState.semiExpanded.height(in: viewport, topInset: topInset)
        let target = ChatPresentationState.snapTarget(
            currentHeight: semiHeight - 5,
            velocity: 0,
            containerHeight: viewport,
            topInset: topInset
        )
        #expect(target == .semiExpanded)
    }

    // MARK: - Progress

    @Test("progress at the minimized anchor is 0")
    func progressAtMinimizedIsZero() {
        let minH = ChatPresentationState.minimized.height(in: viewport)
        let p = ChatPresentationState.progress(forHeight: minH, in: viewport)
        #expect(p == 0)
    }

    @Test("progress at the minimized anchor with a bottom safe area is still 0")
    func progressAtMinimizedWithSafeAreaIsZero() {
        // Real iPhones report a 34pt bottom inset for the home indicator.
        // The minimized anchor height(in:bottomSafeArea:) adds that to
        // `minimizedBaseHeight`. The progress mapping has to use the same
        // safe area for `minH` *and* `maxH` (the expanded anchor returns
        // `containerHeight`, ignoring safe area) or progress at the
        // minimized release would be non-zero whenever the device has a
        // bottom safe area — visually nudging the surround/transcript
        // opacities away from their pill-mode baseline. Verifies the
        // bottom-safe-area handling is symmetric across both endpoints.
        let safeArea: CGFloat = 34
        let minH = ChatPresentationState.minimized.height(in: viewport, bottomSafeArea: safeArea)
        let p = ChatPresentationState.progress(forHeight: minH, in: viewport, bottomSafeArea: safeArea)
        #expect(p == 0)
    }

    @Test("progress at the expanded anchor is 1")
    func progressAtExpandedIsOne() {
        let maxH = ChatPresentationState.expanded.height(in: viewport)
        let p = ChatPresentationState.progress(forHeight: maxH, in: viewport)
        #expect(p == 1)
    }

    @Test("progress at the semi-expanded anchor matches the linear projection")
    func progressAtSemiMatchesLinearProjection() {
        let topInset: CGFloat = 88
        let semiH = ChatPresentationState.semiExpanded.height(in: viewport, topInset: topInset)
        let p = ChatPresentationState.progress(forHeight: semiH, in: viewport, topInset: topInset)
        // (semi - min) / (max - min) — well above 0.5 now because the
        // anchor sits at `containerH - topInset` rather than at half-height.
        let minH = ChatPresentationState.minimizedBaseHeight
        let expected = Double((semiH - minH) / (viewport - minH))
        #expect(abs(p - expected) < 0.001)
    }

    @Test("semiExpandedProgress matches progress at the resolved semi height")
    func semiExpandedProgressMatchesAnchorProgress() {
        // The `AppShell`'s backdrop-dim mid-knot reads `semiExpandedProgress`
        // directly. It must agree with the long-form `progress(forHeight:)`
        // call against the resolved semi anchor for the curve to land on
        // 0.65 opacity precisely at the semi rest position.
        for topInset in stride(from: CGFloat(0), through: 160, by: 20) {
            let semiH = ChatPresentationState.semiExpanded.height(in: viewport, topInset: topInset)
            let p = ChatPresentationState.progress(forHeight: semiH, in: viewport, topInset: topInset)
            let helper = ChatPresentationState.semiExpandedProgress(in: viewport, topInset: topInset)
            #expect(abs(p - helper) < 0.0001)
        }
    }

    @Test("progress clamps to [0, 1] outside the anchor range")
    func progressClamps() {
        let below = ChatPresentationState.progress(forHeight: 0, in: viewport)
        let above = ChatPresentationState.progress(forHeight: viewport + 200, in: viewport)
        #expect(below == 0)
        #expect(above == 1)
    }

    // MARK: - Keyboard-independence of the anchor geometry
    //
    // `ChatComposer.editorInteractive` gates the text field on
    // `progress > editorInteractiveThreshold` and
    // `ChatScreen.pillSurfaceCaptureActive` mounts the tap-to-expand
    // overlay at `progress <= editorInteractiveThreshold`. The container
    // height and bottom inset fed into the anchor geometry therefore
    // decide, via `progress`, whether the composer is a live text field or
    // a tap target. Both must be pure device geometry — never folding in
    // the software keyboard.

    /// The composer-interactivity threshold — the same constant
    /// `ChatComposer` and `ChatScreen` gate on.
    private let editorInteractiveThreshold = ChatPresentationState.editorInteractiveThreshold

    @Test("semi-expanded stays above the composer threshold for every home-indicator inset")
    func semiExpandedProgressStaysInteractiveAcrossHomeIndicatorInsets() {
        // Real devices report a 0–48pt bottom inset for the home
        // indicator. Across that whole range the semi-expanded anchor
        // must resolve well above the 0.15 threshold so a composer that
        // is interactive in semi-expanded mode stays interactive.
        let topInset: CGFloat = 88
        for homeInset in stride(from: CGFloat(0), through: 48, by: 4) {
            let semiH = ChatPresentationState.semiExpanded.height(in: viewport, bottomSafeArea: homeInset, topInset: topInset)
            let p = ChatPresentationState.progress(forHeight: semiH, in: viewport, bottomSafeArea: homeInset, topInset: topInset)
            #expect(p > editorInteractiveThreshold)
        }
    }

    @Test("semi-expanded stays above the composer threshold even under contaminated insets")
    func semiExpandedStaysInteractiveUnderInsetContamination() {
        // Robustness check for the new "containerH - topInset" semi
        // anchor: it sits close enough to the expanded anchor that even
        // an accidentally-keyboard-sized bottom or top inset can't drag
        // its `progress` below the composer-interactivity threshold.
        // The structural defense — `ChatOverlay`'s two-reader split
        // keeping the keyboard out of `topSafeArea` and `bottomSafeArea`
        // — is enforced elsewhere; this test pins that the math
        // tolerates a violation without disabling the field.
        let keyboardInset: CGFloat = 336
        let topInset: CGFloat = 88
        let semiH = ChatPresentationState.semiExpanded.height(
            in: viewport,
            bottomSafeArea: keyboardInset,
            topInset: topInset
        )
        let p = ChatPresentationState.progress(
            forHeight: semiH,
            in: viewport,
            bottomSafeArea: keyboardInset,
            topInset: topInset
        )
        #expect(p > editorInteractiveThreshold)

        // Same anchor, only the bottom inset differs — the realistic
        // home-indicator value also stays well above the threshold.
        let homeInset: CGFloat = 34
        let safe = ChatPresentationState.progress(
            forHeight: semiH,
            in: viewport,
            bottomSafeArea: homeInset,
            topInset: topInset
        )
        #expect(safe > editorInteractiveThreshold)
    }

    // MARK: - Editor-threshold crossing (keyboard dismissal)
    //
    // `ChatScreen` dismisses the keyboard when `progress` crosses below
    // the threshold — disabling the composer's `TextField` does not clear
    // `@FocusState`, so the keyboard would otherwise wedge. The crossing
    // predicate must fire on a genuine collapse and *never* on an expand.

    @Test("a genuine downward crossing of the threshold is detected")
    func crossingBelowThresholdIsDetected() {
        let t = ChatPresentationState.editorInteractiveThreshold
        #expect(ChatPresentationState.crossedBelowEditorThreshold(from: 0.5, to: 0.0))
        // Landing exactly on the threshold counts as crossing below it —
        // `editorInteractive` gates on `> threshold`, so `== threshold`
        // is already non-interactive.
        #expect(ChatPresentationState.crossedBelowEditorThreshold(from: 0.5, to: t))
    }

    @Test("a rising progress never trips the threshold crossing")
    func risingProgressNeverCrosses() {
        // An expand only ever raises `progress` — even the snap curve's
        // end-overshoot raises it past the target, never dips it below
        // the start. So no expand, however animated, can trip a keyboard
        // dismissal. Sweep every from→to pair where `to >= from`.
        for from in stride(from: 0.0, through: 1.0, by: 0.05) {
            for to in stride(from: from, through: 1.0, by: 0.05) {
                #expect(!ChatPresentationState.crossedBelowEditorThreshold(from: from, to: to))
            }
        }
    }

    @Test("a decrease that stays on one side of the threshold does not cross")
    func decreaseWithoutCrossingDoesNotFire() {
        // Collapsing but still interactive — no crossing yet.
        #expect(!ChatPresentationState.crossedBelowEditorThreshold(from: 0.9, to: 0.3))
        // Already below the threshold and collapsing further — the
        // crossing already happened on an earlier tick; don't re-fire.
        #expect(!ChatPresentationState.crossedBelowEditorThreshold(from: 0.1, to: 0.0))
    }

    // MARK: - Rendered surface height (keyboard avoidance)

    @Test("rendered height caps to the space above the keyboard")
    func renderedHeightCapsToKeyboardAwareSpace() {
        // Expanded surface (778pt) with the keyboard up: only 477pt is
        // free above the keyboard, so the surface renders 477pt — short
        // enough that the bottom-pinned composer clears the keyboard.
        let rendered = ChatPresentationState.renderedSurfaceHeight(
            effectiveHeight: 778,
            keyboardAwareHeight: 477
        )
        #expect(rendered == 477)
    }

    @Test("rendered height is the effective height when the surface already fits")
    func renderedHeightUncappedWhenItFits() {
        // Semi-expanded panel (404pt) with the keyboard up (477pt free):
        // the panel already clears the keyboard, so it keeps its full
        // height and simply slides up — no cap applied.
        let fits = ChatPresentationState.renderedSurfaceHeight(
            effectiveHeight: 404,
            keyboardAwareHeight: 477
        )
        #expect(fits == 404)

        // No keyboard: `keyboardAwareHeight` equals the full container, so
        // the rendered height is exactly the effective height.
        let noKeyboard = ChatPresentationState.renderedSurfaceHeight(
            effectiveHeight: 404,
            keyboardAwareHeight: viewport
        )
        #expect(noKeyboard == 404)
    }

    @Test("rendered height never exceeds the keyboard-aware space")
    func renderedHeightNeverExceedsKeyboardAwareSpace() {
        // The composer is pinned to the surface's bottom edge, so as long
        // as the rendered height never exceeds the space above the
        // keyboard the composer can never be pushed off-screen — whatever
        // the effective height resolves to mid-transition.
        for effectiveH in stride(from: CGFloat(60), through: 900, by: 30) {
            for keyboardAwareH in stride(from: CGFloat(300), through: 874, by: 41) {
                let rendered = ChatPresentationState.renderedSurfaceHeight(
                    effectiveHeight: effectiveH,
                    keyboardAwareHeight: keyboardAwareH
                )
                #expect(rendered <= keyboardAwareH)
            }
        }
    }
}
