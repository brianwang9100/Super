import CoreGraphics
import Foundation
import Testing
@testable import Bible

/// Tests for `BibleScreenViewModel`'s scroll-driven immersive reducer
/// (`updateScroll`) — the pure logic that flips `isImmersive` so the Bible
/// nav bar and the shell's chrome hide as the user scrolls into a chapter and
/// return on scroll-up / at the top. Regression coverage for the
/// scroll-to-hide reading-chrome feature.
@Suite("BibleScreenViewModel immersive scroll")
@MainActor
struct BibleScreenViewModelImmersiveTests {
    private func makeViewModel() -> BibleScreenViewModel {
        BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
            narration: NarrationController(service: FakeNarrationService())
        )
    }

    /// A user-driven scroll establishes a baseline without flipping immersive.
    /// Helper: seed the reducer at `offsetY` so a later delta is measured.
    private func seed(_ viewModel: BibleScreenViewModel, at offsetY: CGFloat) {
        viewModel.updateScroll(offsetY: offsetY, userDriven: true)
    }

    @Test("starts non-immersive")
    func startsVisible() {
        #expect(makeViewModel().isImmersive == false)
    }

    @Test("scrolling down past the threshold hides chrome")
    func scrollDownHides() {
        let viewModel = makeViewModel()
        seed(viewModel, at: 80) // baseline, past the min-offset gate
        viewModel.updateScroll(offsetY: 80 + 20, userDriven: true)
        #expect(viewModel.isImmersive == true)
    }

    @Test("scrolling back up reveals chrome again")
    func scrollUpReveals() {
        let viewModel = makeViewModel()
        seed(viewModel, at: 200)
        viewModel.updateScroll(offsetY: 240, userDriven: true)
        #expect(viewModel.isImmersive == true)
        // Any deliberate upward run past the reveal threshold brings it back.
        viewModel.updateScroll(offsetY: 220, userDriven: true)
        #expect(viewModel.isImmersive == false)
    }

    @Test("reaching the top always reveals chrome")
    func topAlwaysReveals() {
        let viewModel = makeViewModel()
        seed(viewModel, at: 300)
        viewModel.updateScroll(offsetY: 340, userDriven: true)
        #expect(viewModel.isImmersive == true)
        // A jump to (near) the top reveals regardless of direction run.
        viewModel.updateScroll(offsetY: 2, userDriven: true)
        #expect(viewModel.isImmersive == false)
    }

    @Test("downward scroll within the first lines keeps chrome (min-offset gate)")
    func belowMinOffsetKeepsChrome() {
        let viewModel = makeViewModel()
        seed(viewModel, at: 10)
        // Accumulates well past the hide threshold, but the reader is still
        // above the min-offset gate, so chrome stays.
        viewModel.updateScroll(offsetY: 40, userDriven: true)
        viewModel.updateScroll(offsetY: 60, userDriven: true)
        #expect(viewModel.isImmersive == false)
    }

    @Test("a small upward jitter does not reveal, but accumulates across reversals")
    func smallUpwardJitterHysteresis() {
        let viewModel = makeViewModel()
        seed(viewModel, at: 200)
        viewModel.updateScroll(offsetY: 240, userDriven: true)
        #expect(viewModel.isImmersive == true)
        // 4pt up — below the reveal threshold — stays hidden.
        viewModel.updateScroll(offsetY: 236, userDriven: true)
        #expect(viewModel.isImmersive == true)
        // Another 4pt up in the same direction crosses the threshold → reveals.
        viewModel.updateScroll(offsetY: 232, userDriven: true)
        #expect(viewModel.isImmersive == false)
    }

    @Test("a small downward jitter past the gate does not hide")
    func smallDownwardJitterKeepsChrome() {
        let viewModel = makeViewModel()
        seed(viewModel, at: 200)
        // +8pt — past the min-offset gate but below the hide threshold.
        viewModel.updateScroll(offsetY: 208, userDriven: true)
        #expect(viewModel.isImmersive == false)
    }

    @Test("re-hides after a reveal — the accumulator resets on each reversal")
    func reHideAfterReveal() {
        let viewModel = makeViewModel()
        seed(viewModel, at: 200)
        viewModel.updateScroll(offsetY: 240, userDriven: true) // down → hide
        #expect(viewModel.isImmersive == true)
        viewModel.updateScroll(offsetY: 200, userDriven: true) // up → reveal
        #expect(viewModel.isImmersive == false)
        viewModel.updateScroll(offsetY: 240, userDriven: true) // down again → re-hide
        #expect(viewModel.isImmersive == true)
    }

    @Test("programmatic (non-user) scroll never flips immersive")
    func programmaticScrollIgnored() {
        let viewModel = makeViewModel()
        seed(viewModel, at: 100)
        // A large programmatic jump (narration follow / deep-link scrollTo)
        // only updates the baseline — it must not hide chrome.
        viewModel.updateScroll(offsetY: 600, userDriven: false)
        #expect(viewModel.isImmersive == false)
        // And measuring resumes from the programmatic baseline: a tiny user
        // delta from 600 is far below the gate's reach, so still visible.
        viewModel.updateScroll(offsetY: 604, userDriven: true)
        #expect(viewModel.isImmersive == false)
    }

    @Test("resetImmersive forces chrome back on")
    func resetForcesVisible() {
        let viewModel = makeViewModel()
        seed(viewModel, at: 200)
        viewModel.updateScroll(offsetY: 240, userDriven: true)
        #expect(viewModel.isImmersive == true)
        viewModel.resetImmersive()
        #expect(viewModel.isImmersive == false)
    }
}
