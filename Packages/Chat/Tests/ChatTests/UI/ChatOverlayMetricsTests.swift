import Foundation
import Testing
@testable import Chat

@Suite("ChatOverlayMetrics resolver")
struct ChatOverlayMetricsTests {
    private let viewport: CGFloat = 874
    private let homeInset: CGFloat = 34
    private let topSafeArea: CGFloat = 44

    private var topInset: CGFloat { topSafeArea + ChatOverlayMetrics.semiExpandedChromeReserve }

    // MARK: - Anchor heights

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
        for raw in stride(from: CGFloat(-200), through: 1_200, by: 25) {
            let metrics = makeMetrics(settled: .semiExpanded, drag: raw)
            #expect(metrics.effectiveHeight >= metrics.minHeight)
            #expect(metrics.effectiveHeight <= metrics.maxHeight)
        }
    }

    // MARK: - Progress

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
        let metrics = makeMetrics(settled: .minimized, drag: -100)
        #expect(metrics.progress == 0)
    }

    // MARK: - Keyboard independence

    // Keyboard space caps rendering; it must not change interaction progress or anchors.

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
        // Expanded has no settled-semi top inset cap, isolating keyboard avoidance.
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

    // MARK: - Settled semi-expanded position

    @Test("settled at semi with no keyboard, the handle sits at topInset")
    func settledSemiHandleAtTopInsetWithoutKeyboard() {
        let metrics = makeMetrics(settled: .semiExpanded, available: viewport)
        #expect(metrics.renderedHeight == viewport - topInset)
    }

    @Test("settled at semi with the keyboard up, the handle still sits at topInset")
    func settledSemiHandleStaysAtTopInsetUnderKeyboard() {
        // The bottom rises with the keyboard; shrinking height by the same amount fixes the handle.
        let available: CGFloat = 538
        let metrics = makeMetrics(settled: .semiExpanded, available: available)
        #expect(metrics.renderedHeight == available - topInset)
    }

    @Test("dragging from semi past the cap renders the full effective height")
    func draggingFromSemiBypassesTopInsetCap() {
        let near = viewport - 10
        let metrics = makeMetrics(
            settled: .semiExpanded,
            drag: near,
            dragTopEdge: 10,
            available: viewport
        )
        #expect(metrics.renderedHeight == near)
    }

    // MARK: - Top-edge drag tracking

    @Test("a no-motion tap at settled semi+keyboard renders at the settled cap")
    func tapAtSemiWithKeyboardDoesNotJump() {
        // A zero-translation gesture must preserve the settled top edge; switching
        // rendering modes at touch-down used to jump the handle to y=0.
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
        // Short windows or large keyboards can leave less space than the top inset.
        let available: CGFloat = topInset - 20
        let metrics = makeMetrics(settled: .semiExpanded, available: available)
        #expect(metrics.renderedHeight == 0)
    }

    @Test("expanded with the keyboard up still caps to the available space, not topInset")
    func expandedWithKeyboardIgnoresTopInsetCap() {
        let available: CGFloat = 538
        let metrics = makeMetrics(settled: .expanded, available: available)
        #expect(metrics.renderedHeight == available)
    }

    @Test("semiExpandedProgress matches the resolved semi anchor's progress")
    func semiExpandedProgressMatchesAnchorProgress() {
        // The backdrop dim curve uses this value for its semi-expanded stop.
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
