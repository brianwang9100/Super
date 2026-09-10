import CoreGraphics
import Foundation
import Testing
@testable import Bible

@Suite("BibleScreenViewModel immersive scroll")
@MainActor
struct BibleScreenViewModelImmersiveTests {
    private func makeViewModel() -> BibleScreenViewModel {
        BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
            narration: NarrationController(service: FakeNarrationService())
        )
    }

    // The first user scroll seeds a baseline without toggling chrome.
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
        viewModel.updateScroll(offsetY: 220, userDriven: true)
        #expect(viewModel.isImmersive == false)
    }

    @Test("reaching the top always reveals chrome")
    func topAlwaysReveals() {
        let viewModel = makeViewModel()
        seed(viewModel, at: 300)
        viewModel.updateScroll(offsetY: 340, userDriven: true)
        #expect(viewModel.isImmersive == true)
        viewModel.updateScroll(offsetY: 2, userDriven: true)
        #expect(viewModel.isImmersive == false)
    }

    @Test("downward scroll within the first lines keeps chrome (min-offset gate)")
    func belowMinOffsetKeepsChrome() {
        let viewModel = makeViewModel()
        seed(viewModel, at: 10)
        viewModel.updateScroll(offsetY: 40, userDriven: true)
        viewModel.updateScroll(offsetY: 60, userDriven: true)
        #expect(viewModel.isImmersive == false)
    }

    @Test("two small upward samples accumulate to cross the reveal threshold")
    func smallUpwardJitterHysteresis() {
        let viewModel = makeViewModel()
        seed(viewModel, at: 200)
        viewModel.updateScroll(offsetY: 240, userDriven: true)
        #expect(viewModel.isImmersive == true)
        viewModel.updateScroll(offsetY: 236, userDriven: true)
        #expect(viewModel.isImmersive == true)
        viewModel.updateScroll(offsetY: 232, userDriven: true)
        #expect(viewModel.isImmersive == false)
    }

    @Test("a small downward jitter past the gate does not hide")
    func smallDownwardJitterKeepsChrome() {
        let viewModel = makeViewModel()
        seed(viewModel, at: 200)
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
        // Programmatic follow/deep-link jumps must update the baseline without hiding chrome.
        viewModel.updateScroll(offsetY: 600, userDriven: false)
        #expect(viewModel.isImmersive == false)
        // Measure the next user delta from the programmatic baseline.
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
