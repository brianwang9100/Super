import Foundation
import Testing
@testable import Bible

/// Tests for `BibleScreenViewModel.isChapterFooterVisible` — the flag the
/// chapter reader drives when its prev / next footer cards scroll into view, so
/// `BibleScreen` hides the (now-redundant) hovering composer chevrons. Reset by
/// `resetImmersive()` on a chapter step so a fresh chapter starts with the
/// chevrons shown.
@Suite("BibleScreenViewModel footer visibility")
@MainActor
struct BibleScreenViewModelFooterVisibilityTests {
    private func makeViewModel() -> BibleScreenViewModel {
        BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
            narration: NarrationController(service: FakeNarrationService())
        )
    }

    @Test("starts with the footer not visible")
    func startsHidden() {
        #expect(makeViewModel().isChapterFooterVisible == false)
    }

    @Test("updateFooterVisibility flips the flag both ways")
    func flipsBothWays() {
        let viewModel = makeViewModel()
        viewModel.updateFooterVisibility(true)
        #expect(viewModel.isChapterFooterVisible == true)
        viewModel.updateFooterVisibility(false)
        #expect(viewModel.isChapterFooterVisible == false)
    }

    @Test("repeating the same value is idempotent")
    func idempotent() {
        let viewModel = makeViewModel()
        viewModel.updateFooterVisibility(true)
        viewModel.updateFooterVisibility(true)
        #expect(viewModel.isChapterFooterVisible == true)
    }

    @Test("resetImmersive clears footer visibility (fresh chapter shows chevrons)")
    func resetClearsFooterVisibility() {
        let viewModel = makeViewModel()
        viewModel.updateFooterVisibility(true)
        viewModel.resetImmersive()
        #expect(viewModel.isChapterFooterVisible == false)
    }
}
