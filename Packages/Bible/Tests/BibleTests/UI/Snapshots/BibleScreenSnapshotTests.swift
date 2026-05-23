#if canImport(UIKit)
import Core
import Foundation
import GRDBQuery
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `BibleScreen` — the chapter reader with its floating nav
/// bar, prev / next footer, verse selection, persisted highlights, and chat
/// stubs.
///
/// The populated state renders the real bundled 1 Peter 2 across the three
/// themes at default and XXL Dynamic Type, per root `AGENTS.md` §Testing.
/// Genesis 1 and Revelation 22 capture the canon's two ends, where a nav
/// arrow and a footer card drop out. The selection state shows the citation
/// pill, the transient selection tint, and the action sheet together; the
/// highlighted state shows verses painted in three persisted colours; the
/// toast state covers the chat "coming soon" stub. The unavailable state
/// covers the "chapter unavailable" fallback.
@Suite("BibleScreen snapshots")
@MainActor
struct BibleScreenSnapshotTests {
    @Test("1 Peter 2 renders in the light theme")
    func populatedLight() async throws {
        verify(await screen(at: BiblePosition(bookId: "1PE", chapterNumber: 2)),
               theme: .light, name: "populated_light")
    }

    @Test("1 Peter 2 renders in the dark theme")
    func populatedDark() async throws {
        verify(await screen(at: BiblePosition(bookId: "1PE", chapterNumber: 2)),
               theme: .dark, name: "populated_dark")
    }

    @Test("1 Peter 2 renders in the sepia theme")
    func populatedSepia() async throws {
        verify(await screen(at: BiblePosition(bookId: "1PE", chapterNumber: 2)),
               theme: .sepia, name: "populated_sepia")
    }

    @Test("1 Peter 2 renders in the light theme at Dynamic Type XXL")
    func populatedLightXXL() async throws {
        verify(await screen(at: BiblePosition(bookId: "1PE", chapterNumber: 2)),
               theme: .light, dynamicType: .xxLarge, name: "populated_light_xxl")
    }

    @Test("1 Peter 2 renders in the dark theme at Dynamic Type XXL")
    func populatedDarkXXL() async throws {
        verify(await screen(at: BiblePosition(bookId: "1PE", chapterNumber: 2)),
               theme: .dark, dynamicType: .xxLarge, name: "populated_dark_xxl")
    }

    @Test("1 Peter 2 renders in the sepia theme at Dynamic Type XXL")
    func populatedSepiaXXL() async throws {
        verify(await screen(at: BiblePosition(bookId: "1PE", chapterNumber: 2)),
               theme: .sepia, dynamicType: .xxLarge, name: "populated_sepia_xxl")
    }

    @Test("Genesis 1 disables the previous arrow and drops the previous footer card")
    func genesisStart() async throws {
        verify(await screen(at: BiblePosition(bookId: "GEN", chapterNumber: 1)),
               theme: .light, name: "genesis_start_light")
    }

    @Test("Revelation 22 disables the next arrow and drops the next footer card")
    func revelationEnd() async throws {
        verify(await screen(at: BiblePosition(bookId: "REV", chapterNumber: 22)),
               theme: .light, name: "revelation_end_light")
    }

    @Test("the unavailable state renders in the light theme")
    func unavailableLight() async {
        verify(await unavailableScreen(), theme: .light, name: "unavailable_light")
    }

    @Test("the unavailable state renders in the dark theme")
    func unavailableDark() async {
        verify(await unavailableScreen(), theme: .dark, name: "unavailable_dark")
    }

    @Test("the book picker renders over the reader in the light theme")
    func bookSheetOpenLight() async {
        let viewModel = BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
            initialPosition: BiblePosition(bookId: "1PE", chapterNumber: 2)
        )
        await viewModel.load()
        viewModel.presentBookSheet()
        verify(BibleScreen(viewModel: viewModel), theme: .light, name: "book_sheet_open_light")
    }

    @Test("selected verses show the citation pill, highlights, and action sheet")
    func selectionActiveLight() async {
        verify(await selectionScreen(), theme: .light, name: "selection_active_light")
    }

    @Test("verse selection renders in the dark theme")
    func selectionActiveDark() async {
        verify(await selectionScreen(), theme: .dark, name: "selection_active_dark")
    }

    @Test("verse selection renders in the sepia theme")
    func selectionActiveSepia() async {
        verify(await selectionScreen(), theme: .sepia, name: "selection_active_sepia")
    }

    @Test("verse selection renders in the light theme at Dynamic Type XXL")
    func selectionActiveLightXXL() async {
        verify(await selectionScreen(), theme: .light, dynamicType: .xxLarge,
               name: "selection_active_light_xxl")
    }

    @Test("verse selection renders in the dark theme at Dynamic Type XXL")
    func selectionActiveDarkXXL() async {
        verify(await selectionScreen(), theme: .dark, dynamicType: .xxLarge,
               name: "selection_active_dark_xxl")
    }

    @Test("verse selection renders in the sepia theme at Dynamic Type XXL")
    func selectionActiveSepiaXXL() async {
        verify(await selectionScreen(), theme: .sepia, dynamicType: .xxLarge,
               name: "selection_active_sepia_xxl")
    }

    @Test("the chat stub raises the coming-soon toast over the reader")
    func chatToastLight() async {
        verify(await toastScreen(), theme: .light, name: "chat_toast_light")
    }

    @Test("the chat toast renders in the dark theme")
    func chatToastDark() async {
        verify(await toastScreen(), theme: .dark, name: "chat_toast_dark")
    }

    @Test("the chat toast renders in the sepia theme")
    func chatToastSepia() async {
        verify(await toastScreen(), theme: .sepia, name: "chat_toast_sepia")
    }

    @Test("the chat toast renders in the light theme at Dynamic Type XXL")
    func chatToastLightXXL() async {
        verify(await toastScreen(), theme: .light, dynamicType: .xxLarge,
               name: "chat_toast_light_xxl")
    }

    @Test("the chat toast renders in the dark theme at Dynamic Type XXL")
    func chatToastDarkXXL() async {
        verify(await toastScreen(), theme: .dark, dynamicType: .xxLarge,
               name: "chat_toast_dark_xxl")
    }

    @Test("the chat toast renders in the sepia theme at Dynamic Type XXL")
    func chatToastSepiaXXL() async {
        verify(await toastScreen(), theme: .sepia, dynamicType: .xxLarge,
               name: "chat_toast_sepia_xxl")
    }

    @Test("persisted highlights paint their verses in the light theme")
    func highlightedLight() async throws {
        verify(try await highlightedScreen(), theme: .light, name: "highlighted_light")
    }

    @Test("persisted highlights render in the dark theme")
    func highlightedDark() async throws {
        verify(try await highlightedScreen(), theme: .dark, name: "highlighted_dark")
    }

    @Test("persisted highlights render in the sepia theme")
    func highlightedSepia() async throws {
        verify(try await highlightedScreen(), theme: .sepia, name: "highlighted_sepia")
    }

    @Test("persisted highlights render in the light theme at Dynamic Type XXL")
    func highlightedLightXXL() async throws {
        verify(try await highlightedScreen(), theme: .light, dynamicType: .xxLarge,
               name: "highlighted_light_xxl")
    }

    @Test("persisted highlights render in the dark theme at Dynamic Type XXL")
    func highlightedDarkXXL() async throws {
        verify(try await highlightedScreen(), theme: .dark, dynamicType: .xxLarge,
               name: "highlighted_dark_xxl")
    }

    @Test("persisted highlights render in the sepia theme at Dynamic Type XXL")
    func highlightedSepiaXXL() async throws {
        verify(try await highlightedScreen(), theme: .sepia, dynamicType: .xxLarge,
               name: "highlighted_sepia_xxl")
    }

    // MARK: - Narration overlay

    @Test("the narration card sits over the populated reader with the active verse underlined")
    func narratingLight() async {
        verify(await narratingScreen(currentVerse: 4),
               theme: .light, name: "narrating_light")
    }

    @Test("the narration card takes precedence over the selection action sheet")
    func narratingWithSelectionLight() async {
        // When the user starts Narrate over a selection, the card and
        // the action sheet would both want to anchor at the bottom.
        // `BibleScreen.bottomOverlay` resolves that by showing only
        // the card while it's visible — this snapshot is the visual
        // guard that the action sheet doesn't leak through underneath.
        verify(await narratingScreen(currentVerse: 5, selecting: [3, 5, 7]),
               theme: .light, name: "narrating_with_selection_light")
    }

    /// A `BibleScreen` whose narration controller is driven into
    /// `.speaking` on `currentVerse`. The fake service lets the test
    /// hold the controller in that state for the snapshot without
    /// invoking the real `AVSpeechSynthesizer`. When `selecting` is
    /// non-empty, those verses are toggled into the selection before
    /// `startNarration` runs — exercises the selection-aware narration
    /// path and the card-over-action-sheet precedence.
    ///
    /// Drives the `.started` event via `NarrationController
    /// ._simulateEvent(_:)` rather than the fake's `AsyncStream` so the
    /// state transition is deterministic, per root AGENTS.md §
    /// Testing.2.
    private func narratingScreen(
        currentVerse: Int,
        selecting verses: [Int] = []
    ) async -> BibleScreen {
        let service = FakeNarrationService()
        let narration = NarrationController(service: service)
        let viewModel = BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
            initialPosition: BiblePosition(bookId: "1PE", chapterNumber: 2),
            narration: narration
        )
        await viewModel.load()
        for verse in verses { viewModel.toggleVerse(verse) }
        viewModel.startNarration()
        narration._simulateEvent(.started(verseNumber: currentVerse))
        return BibleScreen(viewModel: viewModel)
    }

    /// A `BibleScreen` over the real bundled text, loaded to `position`.
    private func screen(at position: BiblePosition) async -> BibleScreen {
        let viewModel = BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
            initialPosition: position
        )
        await viewModel.load()
        return BibleScreen(viewModel: viewModel)
    }

    /// A `BibleScreen` on 1 Peter 2 with verses 4-6 and 9 selected.
    private func selectionScreen() async -> BibleScreen {
        let viewModel = BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
            initialPosition: BiblePosition(bookId: "1PE", chapterNumber: 2)
        )
        await viewModel.load()
        for verse in [4, 5, 6, 9] { viewModel.toggleVerse(verse) }
        return BibleScreen(viewModel: viewModel)
    }

    /// A `BibleScreen` on 1 Peter 2 with the chat "coming soon" toast raised.
    private func toastScreen() async -> BibleScreen {
        let viewModel = BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
            initialPosition: BiblePosition(bookId: "1PE", chapterNumber: 2)
        )
        await viewModel.load()
        viewModel.presentChatComingSoon()
        return BibleScreen(viewModel: viewModel)
    }

    /// A `BibleScreen` whose text loader always fails.
    private func unavailableScreen() async -> BibleScreen {
        let viewModel = BibleScreenViewModel(textLoader: ThrowingBibleTextLoader())
        await viewModel.load()
        return BibleScreen(viewModel: viewModel)
    }

    /// A `BibleScreen` on 1 Peter 2 with three verses highlighted in three
    /// colours, wired to the database context whose `bibleHighlight` rows the
    /// chapter renderer's `@Query` observes. Verses 2, 4, and 7 are chosen so
    /// all three colours sit above the snapshot fold.
    private func highlightedScreen() async throws -> some View {
        let database = try BibleDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let repository = GRDBBibleHighlightRepository(
            database: database, ids: DeterministicIDGenerator()
        )
        try await repository.setHighlight(
            bookId: "1PE", chapterNumber: 2, verseNumber: 2, color: .blue, at: now
        )
        try await repository.setHighlight(
            bookId: "1PE", chapterNumber: 2, verseNumber: 4, color: .yellow, at: now
        )
        try await repository.setHighlight(
            bookId: "1PE", chapterNumber: 2, verseNumber: 7, color: .green, at: now
        )
        let viewModel = BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
            initialPosition: BiblePosition(bookId: "1PE", chapterNumber: 2)
        )
        await viewModel.load()
        return BibleScreen(viewModel: viewModel)
            .databaseContext(.readOnly { database.queue })
    }

    private func verify(
        _ screen: some View,
        theme: SuperTheme.Identifier,
        dynamicType: DynamicTypeSize = .large,
        name: String,
        function: String = #function
    ) {
        let view = screen
            .superTheme(.make(theme))
            .dynamicTypeSize(dynamicType)
            .frame(width: 402, height: 760)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 760)),
            named: name,
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
