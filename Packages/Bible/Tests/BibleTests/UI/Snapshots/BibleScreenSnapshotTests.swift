#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `BibleScreen` — the chapter reader with its floating nav
/// bar, prev / next footer, verse selection, and chat stubs.
///
/// The populated state renders the real bundled 1 Peter 2 across the three
/// themes at default and XXL Dynamic Type, per root `AGENTS.md` §Testing.
/// Genesis 1 and Revelation 22 capture the canon's two ends, where a nav
/// arrow and a footer card drop out. The selection state shows the citation
/// pill, highlighted verses, and the action sheet together; the toast state
/// covers the chat "coming soon" stub. The unavailable state covers the
/// "chapter unavailable" fallback.
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

    @Test("the chat stub raises the coming-soon toast over the reader")
    func chatToastLight() async {
        let viewModel = BibleScreenViewModel(
            textLoader: BundledBibleTextLoader(),
            initialPosition: BiblePosition(bookId: "1PE", chapterNumber: 2)
        )
        await viewModel.load()
        viewModel.presentChatComingSoon()
        verify(BibleScreen(viewModel: viewModel), theme: .light, name: "chat_toast_light")
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

    /// A `BibleScreen` whose text loader always fails.
    private func unavailableScreen() async -> BibleScreen {
        let viewModel = BibleScreenViewModel(textLoader: ThrowingBibleTextLoader())
        await viewModel.load()
        return BibleScreen(viewModel: viewModel)
    }

    private func verify(
        _ screen: BibleScreen,
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
