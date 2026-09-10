import Core
import Foundation
import Testing
@testable import Bible

/// Native sheets sit above the sidebar window; passive sheets must dismiss for the drawer to be visible.
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

    /// Resumes only after sidebar dismissal has been processed.
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

    @Test("opening the sidebar dismisses narration controls while playback continues")
    func dismissesNarrationControlsPreservingPlayback() async {
        let bus = SuperEventBus()
        let viewModel = await makeViewModel(bus: bus)
        viewModel.startNarration()
        viewModel.narration._simulateEvent(.started(verseNumber: 28))
        #expect(viewModel.isNarrationSheetPresented)

        await openSidebarAndAwait(on: bus, through: viewModel)

        #expect(!viewModel.isNarrationSheetPresented)
        #expect(viewModel.narration.state == .speaking)
        #expect(viewModel.narration.currentVerseNumber == 28)
        viewModel.narration.stop()
    }

    @Test("opening the sidebar discards the selector from either tab")
    func dismissesPickers() async {
        let bus = SuperEventBus()
        let viewModel = await makeViewModel(bus: bus)
        viewModel.presentSelectionSheet()
        viewModel.selectionSheet?.tab = .translation
        viewModel.selectionSheet?.translation = .web
        #expect(viewModel.selectionSheet != nil)

        await openSidebarAndAwait(on: bus, through: viewModel)
        #expect(viewModel.selectionSheet == nil)
        #expect(viewModel.translation == .kjv)

        viewModel.presentSelectionSheet()
        #expect(viewModel.selectionSheet != nil)

        await openSidebarAndAwait(on: bus, through: viewModel)
        #expect(viewModel.selectionSheet == nil)
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

    /// Dismissing the disclaimer discards pending intent, so sidebar handoff must preserve this confirmation.
    @Test("opening the sidebar does NOT dismiss the annotation disclaimer")
    func sparesDisclaimerGate() async {
        let bus = SuperEventBus()
        let viewModel = await makeViewModel(bus: bus)
        viewModel.isAnnotationDisclaimerPresented = true

        await openSidebarAndAwait(on: bus, through: viewModel)

        #expect(viewModel.isAnnotationDisclaimerPresented)
    }
}
