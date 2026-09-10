import Foundation
import Testing
@testable import Chat

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
        let h = ChatPresentationState.semiExpanded.height(in: viewport, topInset: 100)
        #expect(h == viewport - 100)
    }

    @Test("semi-expanded anchor falls back to the container with zero top inset")
    func semiExpandedHeightWithNoTopInset() {
        let h = ChatPresentationState.semiExpanded.height(in: viewport)
        #expect(h == viewport)
    }

    @Test("semi-expanded anchor enforces a floor on small viewports")
    func semiExpandedHeightFloorOnSmallViewports() {
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
            currentHeight: viewport - 40,
            velocity: ChatPresentationState.skipVelocity + 100,
            containerHeight: viewport
        )
        #expect(target == .minimized)
    }

    @Test("a hard upward flick jumps to expanded regardless of height")
    func hardUpwardFlickJumpsToExpanded() {
        let target = ChatPresentationState.snapTarget(
            currentHeight: 80,
            velocity: -(ChatPresentationState.skipVelocity + 100),
            containerHeight: viewport
        )
        #expect(target == .expanded)
    }

    @Test("a slow release projects forward by velocity and snaps to nearest")
    func slowReleaseProjectsThenSnaps() {
        let target = ChatPresentationState.snapTarget(
            currentHeight: 300,
            velocity: 250,
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
        // Progress must use the same safe-area-adjusted minimum as the anchor or
        // a settled pill acquires nonzero transcript opacity.
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
        let minH = ChatPresentationState.minimizedBaseHeight
        let expected = Double((semiH - minH) / (viewport - minH))
        #expect(abs(p - expected) < 0.001)
    }

    @Test("semiExpandedProgress matches progress at the resolved semi height")
    func semiExpandedProgressMatchesAnchorProgress() {
        // The backdrop dim curve must place its middle stop at the resolved semi anchor.
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

    // MARK: - Keyboard independence

    // Progress gates composer interaction, so anchor inputs must exclude keyboard geometry.

    private let editorInteractiveThreshold = ChatPresentationState.editorInteractiveThreshold

    @Test("semi-expanded stays above the composer threshold for every home-indicator inset")
    func semiExpandedProgressStaysInteractiveAcrossHomeIndicatorInsets() {
        let topInset: CGFloat = 88
        for homeInset in stride(from: CGFloat(0), through: 48, by: 4) {
            let semiH = ChatPresentationState.semiExpanded.height(in: viewport, bottomSafeArea: homeInset, topInset: topInset)
            let p = ChatPresentationState.progress(forHeight: semiH, in: viewport, bottomSafeArea: homeInset, topInset: topInset)
            #expect(p > editorInteractiveThreshold)
        }
    }

    @Test("semi-expanded stays above the composer threshold even under contaminated insets")
    func semiExpandedStaysInteractiveUnderInsetContamination() {
        // Exercise tolerance of keyboard-sized input even though production separates
        // device geometry from keyboard space.
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

        let homeInset: CGFloat = 34
        let safe = ChatPresentationState.progress(
            forHeight: semiH,
            in: viewport,
            bottomSafeArea: homeInset,
            topInset: topInset
        )
        #expect(safe > editorInteractiveThreshold)
    }

    // MARK: - Editor-threshold crossing

    // Disabling the TextField does not clear FocusState; collapse must explicitly dismiss.

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
        for from in stride(from: 0.0, through: 1.0, by: 0.05) {
            for to in stride(from: from, through: 1.0, by: 0.05) {
                #expect(!ChatPresentationState.crossedBelowEditorThreshold(from: from, to: to))
            }
        }
    }

    @Test("a decrease that stays on one side of the threshold does not cross")
    func decreaseWithoutCrossingDoesNotFire() {
        #expect(!ChatPresentationState.crossedBelowEditorThreshold(from: 0.9, to: 0.3))
        #expect(!ChatPresentationState.crossedBelowEditorThreshold(from: 0.1, to: 0.0))
    }

    // MARK: - Rendered surface height (keyboard avoidance)

    @Test("rendered height caps to the space above the keyboard")
    func renderedHeightCapsToKeyboardAwareSpace() {
        let rendered = ChatPresentationState.renderedSurfaceHeight(
            effectiveHeight: 778,
            keyboardAwareHeight: 477
        )
        #expect(rendered == 477)
    }

    @Test("rendered height is the effective height when the surface already fits")
    func renderedHeightUncappedWhenItFits() {
        let fits = ChatPresentationState.renderedSurfaceHeight(
            effectiveHeight: 404,
            keyboardAwareHeight: 477
        )
        #expect(fits == 404)

        let noKeyboard = ChatPresentationState.renderedSurfaceHeight(
            effectiveHeight: 404,
            keyboardAwareHeight: viewport
        )
        #expect(noKeyboard == 404)
    }

    @Test("rendered height never exceeds the keyboard-aware space")
    func renderedHeightNeverExceedsKeyboardAwareSpace() {
        // The bottom-pinned composer stays visible only while rendering fits above the keyboard.
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
