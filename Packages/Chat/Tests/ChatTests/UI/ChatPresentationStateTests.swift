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

    @Test("semi-expanded anchor uses the design ratio above the floor")
    func semiExpandedHeightUsesRatio() {
        let h = ChatPresentationState.semiExpanded.height(in: viewport)
        #expect(h == viewport * ChatPresentationState.semiExpandedRatio)
    }

    @Test("semi-expanded anchor enforces a floor on small viewports")
    func semiExpandedHeightFloorOnSmallViewports() {
        // 400pt × 0.52 ≈ 208pt — below the 280pt floor.
        let h = ChatPresentationState.semiExpanded.height(in: 400)
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
        let target = ChatPresentationState.semiExpanded.height(in: viewport)
        let nearest = ChatPresentationState.nearestAnchor(forHeight: target + 30, in: viewport)
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
            velocity: ChatOverlayAnimation.skipVelocity + 100, // downward = collapsing
            containerHeight: viewport
        )
        #expect(target == .minimized)
    }

    @Test("a hard upward flick jumps to expanded regardless of height")
    func hardUpwardFlickJumpsToExpanded() {
        let target = ChatPresentationState.snapTarget(
            currentHeight: 80, // basically minimized
            velocity: -(ChatOverlayAnimation.skipVelocity + 100), // upward = expanding
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
        let semiHeight = ChatPresentationState.semiExpanded.height(in: viewport)
        let target = ChatPresentationState.snapTarget(
            currentHeight: semiHeight - 5,
            velocity: 0,
            containerHeight: viewport
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

    @Test("progress at the semi-expanded anchor matches the design ratio")
    func progressAtSemiMatchesRatio() {
        let semiH = ChatPresentationState.semiExpanded.height(in: viewport)
        let p = ChatPresentationState.progress(forHeight: semiH, in: viewport)
        // (semi - min) / (max - min) — close to 0.52 with the small min offset.
        let expected = Double((semiH - ChatPresentationState.minimizedBaseHeight) / (viewport - ChatPresentationState.minimizedBaseHeight))
        #expect(abs(p - expected) < 0.001)
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
    // `progress > 0.15` and `ChatScreen.pillSurfaceCaptureActive` mounts
    // the tap-to-expand overlay at `progress <= 0.15`. The bottom inset
    // fed into the anchor geometry therefore decides, via `progress`,
    // whether the composer is a live text field or a tap target. It must
    // be the home-indicator inset only — never the software keyboard.

    /// The composer-interactivity threshold mirrored from
    /// `ChatComposer.editorInteractive` / `ChatScreen.pillSurfaceCaptureActive`.
    private let editorInteractiveThreshold = 0.15

    @Test("semi-expanded stays above the composer threshold for every home-indicator inset")
    func semiExpandedProgressStaysInteractiveAcrossHomeIndicatorInsets() {
        // Real devices report a 0–48pt bottom inset for the home
        // indicator. Across that whole range the semi-expanded anchor
        // must resolve well above the 0.15 threshold so a composer that
        // is interactive in semi-expanded mode stays interactive.
        for homeInset in stride(from: CGFloat(0), through: 48, by: 4) {
            let semiH = ChatPresentationState.semiExpanded.height(in: viewport, bottomSafeArea: homeInset)
            let p = ChatPresentationState.progress(forHeight: semiH, in: viewport, bottomSafeArea: homeInset)
            #expect(p > editorInteractiveThreshold)
        }
    }

    @Test("a keyboard-sized bottom inset would force semi-expanded below the composer threshold")
    func keyboardSizedInsetCollapsesSemiExpandedProgress() {
        // Regression guard for the composer-wedge bug. Focusing the
        // composer raises the software keyboard, which a `GeometryProxy`
        // folds into `safeAreaInsets.bottom` (~290–340pt on an iPhone).
        // Feeding that inflated inset into the anchor geometry drops the
        // semi-expanded anchor's progress below 0.15, which disables the
        // field mid-keyboard-presentation and wedges the keyboard
        // half-open. `ChatOverlay` resolves the inset from a
        // `.ignoresSafeArea(.keyboard)` probe precisely so this can't
        // happen — this test pins the hazard the probe defends against.
        let keyboardInset: CGFloat = 336
        let semiH = ChatPresentationState.semiExpanded.height(in: viewport, bottomSafeArea: keyboardInset)
        let collapsed = ChatPresentationState.progress(forHeight: semiH, in: viewport, bottomSafeArea: keyboardInset)
        #expect(collapsed < editorInteractiveThreshold)

        // Same anchor, same viewport — only the inset differs. The
        // home-indicator inset keeps the composer interactive, proving
        // the keyboard is the sole cause of the threshold crossing.
        let homeInset: CGFloat = 34
        let safe = ChatPresentationState.progress(forHeight: semiH, in: viewport, bottomSafeArea: homeInset)
        #expect(safe > editorInteractiveThreshold)
    }
}
