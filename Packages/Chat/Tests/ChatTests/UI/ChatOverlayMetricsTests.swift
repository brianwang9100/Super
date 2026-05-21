import Foundation
import Testing
@testable import Chat

/// Tests for `ChatOverlayMetrics` — the pure resolver that takes the three
/// chat-overlay geometry inputs (device geometry, keyboard space,
/// interaction state) and produces every resolved value the SwiftUI views
/// project from (`minHeight`, `maxHeight`, `settledHeight`,
/// `effectiveHeight`, `progress`, `renderedHeight`). Resolves in-process —
/// no view rendering — so layout regressions register here long before they
/// reach the snapshot suite.
@Suite("ChatOverlayMetrics resolver")
struct ChatOverlayMetricsTests {
    private let viewport: CGFloat = 874
    private let homeInset: CGFloat = 34
    private let topSafeArea: CGFloat = 44

    /// Effective top inset the resolver applies — matches the production
    /// formula `topSafeArea + semiExpandedChromeReserve`. Hoisted so
    /// every assertion that re-derives an expected anchor uses the same
    /// inset the resolver did.
    private var topInset: CGFloat { topSafeArea + ChatOverlayMetrics.semiExpandedChromeReserve }

    // MARK: - Anchor heights are derived from `ChatPresentationState`

    @Test("minHeight matches the minimized anchor's resolved height")
    func minHeightMatchesMinimizedAnchor() {
        let metrics = makeMetrics(settled: .semiExpanded)
        #expect(metrics.minHeight == ChatPresentationState.minimized.height(in: viewport, bottomSafeArea: homeInset, topInset: topInset))
    }

    @Test("maxHeight matches the expanded anchor's resolved height")
    func maxHeightMatchesExpandedAnchor() {
        let metrics = makeMetrics(settled: .semiExpanded)
        #expect(metrics.maxHeight == ChatPresentationState.expanded.height(in: viewport, bottomSafeArea: homeInset, topInset: topInset))
    }

    @Test("settledHeight matches the supplied anchor's resolved height")
    func settledHeightMatchesSettledAnchor() {
        for anchor in ChatPresentationState.allCases {
            let metrics = makeMetrics(settled: anchor)
            #expect(metrics.settledHeight == anchor.height(in: viewport, bottomSafeArea: homeInset, topInset: topInset))
        }
    }

    @Test("settled at semi reserves topSafeArea + chromeReserve from the container")
    func semiSettledHeightLeavesTopInsetReserved() {
        // 874pt viewport - (44pt safe area + 52pt chrome reserve) = 778pt.
        // The handle ends up at y = 96pt — flush below the backdrop applet's
        // nav bar, per the user-facing "drawer under the nav bar" intent.
        let metrics = makeMetrics(settled: .semiExpanded)
        #expect(metrics.settledHeight == viewport - topInset)
    }

    // MARK: - Interaction precedence and clamping

    @Test("a drag height overrides the settled-anchor height")
    func dragHeightOverridesSettled() {
        let metrics = makeMetrics(settled: .minimized, drag: 400)
        #expect(metrics.effectiveHeight == 400)
    }

    @Test("with no drag the effective height is the settled-anchor height")
    func noDragUsesSettledHeight() {
        let metrics = makeMetrics(settled: .semiExpanded)
        #expect(metrics.effectiveHeight == metrics.settledHeight)
    }

    @Test("effective height clamps below to the minimized anchor")
    func effectiveHeightClampsBelowToMin() {
        // A drag below the minimized anchor (impossible via gesture but
        // defensive — caps the resolved geometry regardless of caller).
        let metrics = makeMetrics(settled: .minimized, drag: 0)
        #expect(metrics.effectiveHeight == metrics.minHeight)
    }

    @Test("effective height clamps above to the expanded anchor")
    func effectiveHeightClampsAboveToMax() {
        let metrics = makeMetrics(settled: .expanded, drag: viewport + 500)
        #expect(metrics.effectiveHeight == metrics.maxHeight)
    }

    @Test("effective height is never below minHeight for any raw input")
    func effectiveHeightNeverBelowMin() {
        // Plan §Verification: `min(maxH, max(minH, rawH)) >= minH` for any rawH.
        for raw in stride(from: CGFloat(-200), through: 1_200, by: 25) {
            let metrics = makeMetrics(settled: .semiExpanded, drag: raw)
            #expect(metrics.effectiveHeight >= metrics.minHeight)
            #expect(metrics.effectiveHeight <= metrics.maxHeight)
        }
    }

    // MARK: - Progress is computed from the resolved effective height

    @Test("progress at the minimized anchor is 0")
    func progressAtMinimizedIsZero() {
        let metrics = makeMetrics(settled: .minimized)
        #expect(metrics.progress == 0)
    }

    @Test("progress at the expanded anchor is 1")
    func progressAtExpandedIsOne() {
        let metrics = makeMetrics(settled: .expanded)
        #expect(metrics.progress == 1)
    }

    @Test("progress reflects effective height, not the raw drag height")
    func progressUsesClampedEffectiveHeight() {
        // A drag below the minimized anchor clamps to min, so progress is 0
        // — not negative. The clamp must apply *before* progress is mapped.
        let metrics = makeMetrics(settled: .minimized, drag: -100)
        #expect(metrics.progress == 0)
    }

    // MARK: - Keyboard-independence (the R1 invariant)
    //
    // The whole point of separating the three geometry inputs: device
    // geometry + interaction resolve `progress`, *and that's it*. The
    // keyboard input only caps `renderedHeight`. Sweep `availableHeight`
    // and confirm `progress` / anchor heights / `effectiveHeight` are
    // bit-stable.

    @Test("anchor heights and progress are independent of keyboard availability")
    func anchorMathIsIndependentOfKeyboardAvailability() {
        let noKeyboard = makeMetrics(settled: .semiExpanded, available: viewport)
        for available in stride(from: CGFloat(300), through: viewport, by: 41) {
            let withKeyboard = makeMetrics(settled: .semiExpanded, available: available)
            #expect(withKeyboard.minHeight == noKeyboard.minHeight)
            #expect(withKeyboard.maxHeight == noKeyboard.maxHeight)
            #expect(withKeyboard.settledHeight == noKeyboard.settledHeight)
            #expect(withKeyboard.effectiveHeight == noKeyboard.effectiveHeight)
            #expect(withKeyboard.progress == noKeyboard.progress)
        }
    }

    // MARK: - Rendered height (keyboard avoidance)

    @Test("rendered height caps to the keyboard-available space")
    func renderedHeightCapsToAvailableSpace() {
        let metrics = makeMetrics(settled: .expanded, available: 477)
        #expect(metrics.renderedHeight == 477)
    }

    @Test("rendered height is the effective height when it already fits")
    func renderedHeightUncappedWhenItFits() {
        // Use `.expanded` so the settled-semi top-inset cap (which would
        // make the rendered height < effective even with no keyboard up)
        // doesn't muddy this base-case assertion.
        let metrics = makeMetrics(settled: .expanded, available: viewport)
        #expect(metrics.renderedHeight == metrics.effectiveHeight)
    }

    @Test("rendered height never exceeds the keyboard-available space")
    func renderedHeightNeverExceedsAvailableSpace() {
        for raw in stride(from: CGFloat(60), through: 900, by: 30) {
            for available in stride(from: CGFloat(300), through: viewport, by: 41) {
                let metrics = makeMetrics(settled: .semiExpanded, drag: raw, available: available)
                #expect(metrics.renderedHeight <= available)
            }
        }
    }

    // MARK: - Settled-semi keeps the handle's y position fixed under the keyboard

    @Test("settled at semi with no keyboard, the handle sits at topInset")
    func settledSemiHandleAtTopInsetWithoutKeyboard() {
        // No keyboard: kbAwareH == containerH. The handle's y position
        // is `containerH - renderedHeight` (the surface is bottom-pinned
        // to the keyboard-aware region). renderedHeight should equal
        // `viewport - topInset` so the handle lands at y = topInset.
        let metrics = makeMetrics(settled: .semiExpanded, available: viewport)
        #expect(metrics.renderedHeight == viewport - topInset)
    }

    @Test("settled at semi with the keyboard up, the handle still sits at topInset")
    func settledSemiHandleStaysAtTopInsetUnderKeyboard() {
        // Keyboard up: kbAwareH < containerH. The surface bottom rises
        // to the keyboard's top, but the handle should NOT move — the
        // user-facing "handle stays in place" guarantee. Achieved by
        // shrinking the rendered height by the same delta the bottom
        // rose. With viewport=874, kbAwareH=538 (≈336pt keyboard), the
        // rendered height becomes 538 - 96 = 442 so the top edge
        // (538 - 442) lands at 96 — exactly topInset.
        let available: CGFloat = 538
        let metrics = makeMetrics(settled: .semiExpanded, available: available)
        #expect(metrics.renderedHeight == available - topInset)
    }

    @Test("dragging from semi past the cap renders the full effective height")
    func draggingFromSemiBypassesTopInsetCap() {
        // A user dragging from semi toward expanded with no keyboard up
        // should see the surface grow continuously past the semi
        // anchor — the cap only applies at the settled rest position so
        // a drag can still climb to the screen edge. The drag-time
        // branch is driven by `dragTopEdge` (kbAwareH - renderedHeight),
        // so a top edge of 10pt yields a rendered height of 864pt.
        let near = viewport - 10
        let metrics = makeMetrics(
            settled: .semiExpanded,
            drag: near,
            dragTopEdge: 10,
            available: viewport
        )
        #expect(metrics.renderedHeight == near)
    }

    // MARK: - Top-edge drag tracking (regression: tap-on-handle jump)

    @Test("a no-motion tap at settled semi+keyboard renders at the settled cap")
    func tapAtSemiWithKeyboardDoesNotJump() {
        // Regression: at settled semi-expanded with the keyboard up,
        // tapping the drag handle fires `onChanged` with translation=0,
        // which sets `dragHeight` to the settled height and (under the
        // prior binary-cap model) flipped the rendered height from
        // `kbAwareH - topInset` to `kbAwareH` in a single frame —
        // making the handle jump from y=topInset to y=0. The top-edge-
        // tracking model captures the start top edge at `kbAwareH -
        // renderedHeight = topInset`, so a tap (`startTopEdge + 0 =
        // topInset`) renders at `kbAwareH - topInset` — identical to
        // the settled value. No jump.
        let available: CGFloat = 538
        let settledRenderedH = available - topInset
        let metrics = makeMetrics(
            settled: .semiExpanded,
            drag: viewport - topInset,
            dragTopEdge: topInset,
            available: available
        )
        #expect(metrics.renderedHeight == settledRenderedH)
    }

    @Test("dragging up from semi+keyboard moves the top edge with the finger")
    func dragUpFromSemiTracksTopEdge() {
        // User drags up 50pt from the settled semi handle position.
        // dragTopEdge = topInset - 50, so renderedHeight = kbAwareH -
        // (topInset - 50) = (kbAwareH - topInset) + 50 — the surface
        // grew by exactly 50pt at the top.
        let available: CGFloat = 538
        let topEdge = topInset - 50
        let metrics = makeMetrics(
            settled: .semiExpanded,
            drag: viewport - topEdge,
            dragTopEdge: topEdge,
            available: available
        )
        #expect(metrics.renderedHeight == available - topEdge)
    }

    @Test("dragging down from semi+keyboard moves the top edge with the finger")
    func dragDownFromSemiTracksTopEdge() {
        // User drags down 200pt from the settled semi handle position.
        // dragTopEdge = topInset + 200, so renderedHeight = kbAwareH -
        // (topInset + 200) — the surface shrank by exactly 200pt at
        // the top.
        let available: CGFloat = 538
        let topEdge = topInset + 200
        let metrics = makeMetrics(
            settled: .semiExpanded,
            drag: viewport - topEdge,
            dragTopEdge: topEdge,
            available: available
        )
        #expect(metrics.renderedHeight == available - topEdge)
    }

    @Test("dragging up from minimized tracks the top edge through the full envelope")
    func dragUpFromMinimizedTracksTopEdge() {
        // No keyboard, settled at minimized; user drags up 700pt from
        // the pill. dragTopEdge = kbAwareH - (minH + 700), so
        // renderedHeight = minH + 700 — the surface follows the finger
        // through the full envelope on its way toward the expanded
        // anchor.
        let metrics = makeMetrics(settled: .minimized)
        let minH = metrics.minHeight
        let topEdge = viewport - (minH + 700)
        let dragged = makeMetrics(
            settled: .minimized,
            drag: minH + 700,
            dragTopEdge: topEdge,
            available: viewport
        )
        #expect(dragged.renderedHeight == minH + 700)
    }

    @Test("settled rendered height is floored at 0 when topInset exceeds keyboard-available space")
    func settledRenderedHeightFlooredAtZero() {
        // Defensive: landscape iPhone with a full-screen keyboard or a
        // very short split-view window can drive `availableHeight`
        // below `topInset`, which would produce a negative
        // `.frame(height:)` (silently rendering nothing) without the
        // floor inside `renderedSurfaceHeight`.
        let available: CGFloat = topInset - 20
        let metrics = makeMetrics(settled: .semiExpanded, available: available)
        #expect(metrics.renderedHeight == 0)
    }

    @Test("expanded with the keyboard up still caps to the available space, not topInset")
    func expandedWithKeyboardIgnoresTopInsetCap() {
        // The top-inset cap is semi-only by intent — expanded keeps the
        // existing `min(effectiveH, kbAwareH)` so the surface lifts with
        // the keyboard's top, top edge sitting at y=0.
        let available: CGFloat = 538
        let metrics = makeMetrics(settled: .expanded, available: available)
        #expect(metrics.renderedHeight == available)
    }

    @Test("semiExpandedProgress matches the resolved semi anchor's progress")
    func semiExpandedProgressMatchesAnchorProgress() {
        // The backdrop dim curve's mid-knot reads this value; it must
        // agree with the long-form `progress(forHeight: semiH, …)` so
        // 0.65 opacity lands at the actual semi rest position.
        let metrics = makeMetrics(settled: .semiExpanded)
        let expected = ChatPresentationState.semiExpandedProgress(
            in: viewport,
            bottomSafeArea: homeInset,
            topInset: topInset
        )
        #expect(abs(metrics.semiExpandedProgress - expected) < 0.0001)
    }

    // MARK: - Value semantics

    @Test("metrics with the same inputs are equal")
    func equatableAcrossIdenticalInputs() {
        let a = makeMetrics(settled: .semiExpanded)
        let b = makeMetrics(settled: .semiExpanded)
        #expect(a == b)
    }

    // MARK: - Builder

    private func makeMetrics(
        settled: ChatPresentationState,
        drag: CGFloat? = nil,
        dragTopEdge: CGFloat? = nil,
        available: CGFloat? = nil
    ) -> ChatOverlayMetrics {
        ChatOverlayMetrics(
            device: .init(
                containerHeight: viewport,
                bottomSafeArea: homeInset,
                topSafeArea: topSafeArea
            ),
            keyboard: .init(availableHeight: available ?? viewport),
            interaction: .init(
                settledState: settled,
                dragHeight: drag,
                dragTopEdge: dragTopEdge
            )
        )
    }
}
