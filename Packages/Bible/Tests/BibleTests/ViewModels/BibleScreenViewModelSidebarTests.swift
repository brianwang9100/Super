import Core
import Foundation
import Testing
@testable import Bible

/// Tests for `BibleScreenViewModel`'s reaction to the shell's
/// `SuperEvent.sidebarOpened` envelope: a native sheet renders in its own
/// window above the in-view sidebar drawer, so when the drawer opens the
/// view model must dismiss whatever sheet it's presenting or the menu
/// slides in behind it.
///
/// Synchronization (per AGENTS.md §2 — no `Task.yield()` polling): publish
/// `sidebarOpened` and await the view model's subscription processing it
/// through the `_onNextSidebarDismiss` test seam, which fires after the
/// dismissal has run. The assertion that follows sees the post-event state
/// deterministically.
@Suite("BibleScreenViewModel sidebar handoff")
@MainActor
struct BibleScreenViewModelSidebarTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private struct AckedDisclaimerStore: AnnotationDisclaimerStore, Sendable {
        var isAcknowledged: Bool { true }
        func setAcknowledged(_ value: Bool) {}
    }

    private func makeViewModel(bus: SuperEventBus) async -> BibleScreenViewModel {
        let viewModel = BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
            clock: FixedClock(now),
            idGenerator: DeterministicIDGenerator(prefix: "req-", start: 0),
            disclaimerStore: AckedDisclaimerStore(),
            initialPosition: BiblePosition(bookId: "ROM", chapterNumber: 8),
            narration: NarrationController(service: FakeNarrationService())
        )
        await viewModel.load()
        await viewModel.attach(to: bus)
        return viewModel
    }

    /// Publish `sidebarOpened` and await the view model's subscription
    /// processing it. `_onNextSidebarDismiss` resumes the continuation only
    /// after the dismissal has run, so the trailing assertion is race-free.
    private func openSidebarAndAwait(
        on bus: SuperEventBus,
        through viewModel: BibleScreenViewModel
    ) async {
        await withCheckedContinuation { continuation in
            viewModel._onNextSidebarDismiss {
                continuation.resume()
            }
            Task {
                await bus.publish(.sidebarOpened)
            }
        }
    }

    @Test("opening the sidebar dismisses verse actions while preserving selection")
    func dismissesActionSheetKeepingSelection() async {
        let bus = SuperEventBus()
        let viewModel = await makeViewModel(bus: bus)
        viewModel.toggleVerse(28)
        #expect(viewModel.isActionSheetPresented)

        await openSidebarAndAwait(on: bus, through: viewModel)

        #expect(!viewModel.isActionSheetPresented)
        #expect(viewModel.selectedVerses == [28])
    }

    @Test("opening the sidebar dismisses the narration sheet")
    func dismissesNarration() async {
        let bus = SuperEventBus()
        let viewModel = await makeViewModel(bus: bus)
        viewModel.presentNarrationSheet()
        #expect(viewModel.isNarrationSheetPresented)

        await openSidebarAndAwait(on: bus, through: viewModel)

        #expect(!viewModel.isNarrationSheetPresented)
    }

    @Test("opening the sidebar dismisses the book and translation pickers")
    func dismissesPickers() async {
        let bus = SuperEventBus()
        let viewModel = await makeViewModel(bus: bus)
        viewModel.presentBookSheet()
        #expect(viewModel.bookSheet != nil)

        await openSidebarAndAwait(on: bus, through: viewModel)
        #expect(viewModel.bookSheet == nil)

        viewModel.presentTranslationSheet()
        #expect(viewModel.isTranslationSheetPresented)

        await openSidebarAndAwait(on: bus, through: viewModel)
        #expect(!viewModel.isTranslationSheetPresented)
    }

    @Test("opening the sidebar dismisses the annotation sheet and the note list")
    func dismissesAnnotationAndNoteList() async {
        let bus = SuperEventBus()
        let viewModel = await makeViewModel(bus: bus)
        viewModel.presentedAnnotationTarget = .chapter(bookId: "ROM", chapterNumber: 8)
        viewModel.presentNoteList(for: .chapter(bookId: "ROM", chapterNumber: 8))
        #expect(viewModel.presentedAnnotationTarget != nil)
        #expect(viewModel.presentedNoteList != nil)

        await openSidebarAndAwait(on: bus, through: viewModel)

        #expect(viewModel.presentedAnnotationTarget == nil)
        #expect(viewModel.presentedNoteList == nil)
    }

    /// The annotation disclaimer is a confirmation gate, not a passive
    /// sheet — `dismissPresentedSheets()` deliberately spares it because
    /// dismissing it discards the user's pending annotation intent. This
    /// locks that invariant in so a future refactor can't start dismissing
    /// it without a failing test.
    @Test("opening the sidebar does NOT dismiss the annotation disclaimer")
    func sparesDisclaimerGate() async {
        let bus = SuperEventBus()
        let viewModel = await makeViewModel(bus: bus)
        viewModel.isAnnotationDisclaimerPresented = true

        await openSidebarAndAwait(on: bus, through: viewModel)

        #expect(viewModel.isAnnotationDisclaimerPresented)
    }
}
