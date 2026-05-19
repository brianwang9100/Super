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

    // MARK: - Anchor heights are derived from `ChatPresentationState`

    @Test("minHeight matches the minimized anchor's resolved height")
    func minHeightMatchesMinimizedAnchor() {
        let metrics = makeMetrics(settled: .semiExpanded)
        #expect(metrics.minHeight == ChatPresentationState.minimized.height(in: viewport, bottomSafeArea: homeInset))
    }

    @Test("maxHeight matches the expanded anchor's resolved height")
    func maxHeightMatchesExpandedAnchor() {
        let metrics = makeMetrics(settled: .semiExpanded)
        #expect(metrics.maxHeight == ChatPresentationState.expanded.height(in: viewport, bottomSafeArea: homeInset))
    }

    @Test("settledHeight matches the supplied anchor's resolved height")
    func settledHeightMatchesSettledAnchor() {
        for anchor in ChatPresentationState.allCases {
            let metrics = makeMetrics(settled: anchor)
            #expect(metrics.settledHeight == anchor.height(in: viewport, bottomSafeArea: homeInset))
        }
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
        let metrics = makeMetrics(settled: .semiExpanded, available: viewport)
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
        available: CGFloat? = nil
    ) -> ChatOverlayMetrics {
        ChatOverlayMetrics(
            device: .init(containerHeight: viewport, bottomSafeArea: homeInset),
            keyboard: .init(availableHeight: available ?? viewport),
            interaction: .init(settledState: settled, dragHeight: drag)
        )
    }
}
