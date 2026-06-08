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
/// pill and the solid selection underline; the narration state shows the
/// active verse underlined; the highlighted state shows verses painted in
/// three persisted colours; the toast state covers the chat "coming soon"
/// stub. The unavailable state covers the "chapter unavailable" fallback.
///
/// The bottom sheets (action sheet, narration card, book / translation
/// pickers) present as native `.sheet`s, which `swift-snapshot-testing` can't
/// capture in its single layout pass — these suites therefore snapshot only
/// the reader-side decorations a selection / narration produces. The sheet
/// content itself is covered directly by `BibleActionSheetSnapshotTests`,
/// `NarrationTransportSheetSnapshotTests`, `BibleBookSheetSnapshotTests`, and
/// `BibleTranslationSheetSnapshotTests`.
@Suite("BibleScreen snapshots")
@MainActor
struct BibleScreenSnapshotTests {
    /// Register Core's bundled brand fonts before any render so the chapter
    /// title and section headings resolve their brand serif instead of baking
    /// the system fallback — and so this suite stays order-independent (font
    /// registration is process-global; see `SnapshotFontRegistration`).
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("1 Peter 2 renders in the light theme")
    func populatedLight() async throws {
        verify(await screen(at: BiblePosition(bookId: "1PE", chapterNumber: 2)),
               theme: .vellumLight, name: "populated_light")
    }

    @Test("1 Peter 2 renders in the dark theme")
    func populatedDark() async throws {
        verify(await screen(at: BiblePosition(bookId: "1PE", chapterNumber: 2)),
               theme: .vellumDark, name: "populated_dark")
    }

    @Test("1 Peter 2 renders in the sepia theme")
    func populatedSepia() async throws {
        verify(await screen(at: BiblePosition(bookId: "1PE", chapterNumber: 2)),
               theme: .sepiaLight, name: "populated_sepia")
    }

    @Test("1 Peter 2 renders in the light theme at Dynamic Type XXL")
    func populatedLightXXL() async throws {
        verify(await screen(at: BiblePosition(bookId: "1PE", chapterNumber: 2)),
               theme: .vellumLight, dynamicType: .xxLarge, name: "populated_light_xxl")
    }

    @Test("1 Peter 2 renders in the dark theme at Dynamic Type XXL")
    func populatedDarkXXL() async throws {
        verify(await screen(at: BiblePosition(bookId: "1PE", chapterNumber: 2)),
               theme: .vellumDark, dynamicType: .xxLarge, name: "populated_dark_xxl")
    }

    @Test("1 Peter 2 renders in the sepia theme at Dynamic Type XXL")
    func populatedSepiaXXL() async throws {
        verify(await screen(at: BiblePosition(bookId: "1PE", chapterNumber: 2)),
               theme: .sepiaLight, dynamicType: .xxLarge, name: "populated_sepia_xxl")
    }

    @Test("1 Peter 2 scales with the app font-scale slider at max in the light theme")
    func populatedFontScaleMaxLight() async throws {
        verify(await screen(at: BiblePosition(bookId: "1PE", chapterNumber: 2)),
               theme: .vellumLight, fontScale: 1.2, name: "populated_font_scale_max_light")
    }

    @Test("1 Peter 2 scales with the app font-scale slider at max in the dark theme")
    func populatedFontScaleMaxDark() async throws {
        verify(await screen(at: BiblePosition(bookId: "1PE", chapterNumber: 2)),
               theme: .vellumDark, fontScale: 1.2, name: "populated_font_scale_max_dark")
    }

    @Test("1 Peter 2 scales with the app font-scale slider at max in the sepia theme")
    func populatedFontScaleMaxSepia() async throws {
        verify(await screen(at: BiblePosition(bookId: "1PE", chapterNumber: 2)),
               theme: .sepiaLight, fontScale: 1.2, name: "populated_font_scale_max_sepia")
    }

    @Test("1 Peter 2 scales with the app font-scale slider at min in the light theme")
    func populatedFontScaleMinLight() async throws {
        verify(await screen(at: BiblePosition(bookId: "1PE", chapterNumber: 2)),
               theme: .vellumLight, fontScale: 0.8, name: "populated_font_scale_min_light")
    }

    @Test("1 Peter 2 scales with the app font-scale slider at min in the dark theme")
    func populatedFontScaleMinDark() async throws {
        verify(await screen(at: BiblePosition(bookId: "1PE", chapterNumber: 2)),
               theme: .vellumDark, fontScale: 0.8, name: "populated_font_scale_min_dark")
    }

    @Test("1 Peter 2 scales with the app font-scale slider at min in the sepia theme")
    func populatedFontScaleMinSepia() async throws {
        verify(await screen(at: BiblePosition(bookId: "1PE", chapterNumber: 2)),
               theme: .sepiaLight, fontScale: 0.8, name: "populated_font_scale_min_sepia")
    }

    @Test("Genesis 1 disables the previous arrow and drops the previous footer card")
    func genesisStart() async throws {
        verify(await screen(at: BiblePosition(bookId: "GEN", chapterNumber: 1)),
               theme: .vellumLight, name: "genesis_start_light")
    }

    @Test("Revelation 22 disables the next arrow and drops the next footer card")
    func revelationEnd() async throws {
        verify(await screen(at: BiblePosition(bookId: "REV", chapterNumber: 22)),
               theme: .vellumLight, name: "revelation_end_light")
    }

    @Test("the unavailable state renders in the light theme")
    func unavailableLight() async {
        verify(await unavailableScreen(), theme: .vellumLight, name: "unavailable_light")
    }

    @Test("the unavailable state renders in the dark theme")
    func unavailableDark() async {
        verify(await unavailableScreen(), theme: .vellumDark, name: "unavailable_dark")
    }

    @Test("selected verses show the citation pill and the selection underline")
    func selectionActiveLight() async {
        verify(await selectionScreen(), theme: .vellumLight, name: "selection_active_light")
    }

    @Test("verse selection renders in the dark theme")
    func selectionActiveDark() async {
        verify(await selectionScreen(), theme: .vellumDark, name: "selection_active_dark")
    }

    @Test("verse selection renders in the sepia theme")
    func selectionActiveSepia() async {
        verify(await selectionScreen(), theme: .sepiaLight, name: "selection_active_sepia")
    }

    @Test("verse selection renders in the light theme at Dynamic Type XXL")
    func selectionActiveLightXXL() async {
        verify(await selectionScreen(), theme: .vellumLight, dynamicType: .xxLarge,
               name: "selection_active_light_xxl")
    }

    @Test("verse selection renders in the dark theme at Dynamic Type XXL")
    func selectionActiveDarkXXL() async {
        verify(await selectionScreen(), theme: .vellumDark, dynamicType: .xxLarge,
               name: "selection_active_dark_xxl")
    }

    @Test("verse selection renders in the sepia theme at Dynamic Type XXL")
    func selectionActiveSepiaXXL() async {
        verify(await selectionScreen(), theme: .sepiaLight, dynamicType: .xxLarge,
               name: "selection_active_sepia_xxl")
    }

    /// Pins the scale-aware underline weight at its 1pt floor: at the 0.8× slider
    /// the rule rounds to 1pt (vs 2pt at the default size the tests above cover).
    /// The weight is theme-independent, so one theme locks the behaviour.
    @Test("verse selection underline thins to its 1pt floor at the min font scale")
    func selectionActiveFontScaleMinLight() async {
        verify(await selectionScreen(), theme: .vellumLight, fontScale: 0.8,
               name: "selection_active_font_scale_min_light")
    }

    @Test("the chat stub raises the coming-soon toast over the reader")
    func chatToastLight() async {
        verify(await toastScreen(), theme: .vellumLight, name: "chat_toast_light")
    }

    @Test("the chat toast renders in the dark theme")
    func chatToastDark() async {
        verify(await toastScreen(), theme: .vellumDark, name: "chat_toast_dark")
    }

    @Test("the chat toast renders in the sepia theme")
    func chatToastSepia() async {
        verify(await toastScreen(), theme: .sepiaLight, name: "chat_toast_sepia")
    }

    @Test("the chat toast renders in the light theme at Dynamic Type XXL")
    func chatToastLightXXL() async {
        verify(await toastScreen(), theme: .vellumLight, dynamicType: .xxLarge,
               name: "chat_toast_light_xxl")
    }

    @Test("the chat toast renders in the dark theme at Dynamic Type XXL")
    func chatToastDarkXXL() async {
        verify(await toastScreen(), theme: .vellumDark, dynamicType: .xxLarge,
               name: "chat_toast_dark_xxl")
    }

    @Test("the chat toast renders in the sepia theme at Dynamic Type XXL")
    func chatToastSepiaXXL() async {
        verify(await toastScreen(), theme: .sepiaLight, dynamicType: .xxLarge,
               name: "chat_toast_sepia_xxl")
    }

    @Test("persisted highlights paint their verses in the light theme")
    func highlightedLight() async throws {
        verify(try await highlightedScreen(), theme: .vellumLight, name: "highlighted_light")
    }

    @Test("persisted highlights render in the dark theme")
    func highlightedDark() async throws {
        verify(try await highlightedScreen(), theme: .vellumDark, name: "highlighted_dark")
    }

    @Test("persisted highlights render in the sepia theme")
    func highlightedSepia() async throws {
        verify(try await highlightedScreen(), theme: .sepiaLight, name: "highlighted_sepia")
    }

    @Test("persisted highlights render in the light theme at Dynamic Type XXL")
    func highlightedLightXXL() async throws {
        verify(try await highlightedScreen(), theme: .vellumLight, dynamicType: .xxLarge,
               name: "highlighted_light_xxl")
    }

    @Test("persisted highlights render in the dark theme at Dynamic Type XXL")
    func highlightedDarkXXL() async throws {
        verify(try await highlightedScreen(), theme: .vellumDark, dynamicType: .xxLarge,
               name: "highlighted_dark_xxl")
    }

    @Test("persisted highlights render in the sepia theme at Dynamic Type XXL")
    func highlightedSepiaXXL() async throws {
        verify(try await highlightedScreen(), theme: .sepiaLight, dynamicType: .xxLarge,
               name: "highlighted_sepia_xxl")
    }

    // The min slider (0.8×) is where the wash's height divergence on the
    // verse-number cell was largest — its raised marker inflated that cell's box,
    // and a box-filling `.background` washed it taller than its neighbors, breaking
    // the seam. The wash is now a baseline-anchored fixed-height band, so every
    // word's wash matches. These guard that fix.
    @Test("persisted highlights paint a seamless band at the min font scale (light)")
    func highlightedFontScaleMinLight() async throws {
        verify(try await highlightedScreen(), theme: .vellumLight, fontScale: 0.8,
               name: "highlighted_font_scale_min_light")
    }

    @Test("persisted highlights paint a seamless band at the min font scale (dark)")
    func highlightedFontScaleMinDark() async throws {
        verify(try await highlightedScreen(), theme: .vellumDark, fontScale: 0.8,
               name: "highlighted_font_scale_min_dark")
    }

    @Test("persisted highlights paint a seamless band at the min font scale (sepia)")
    func highlightedFontScaleMinSepia() async throws {
        verify(try await highlightedScreen(), theme: .sepiaLight, fontScale: 0.8,
               name: "highlighted_font_scale_min_sepia")
    }

    // MARK: - Immersive reading (scroll-hidden nav bar)

    @Test("scrolling down hides the nav bar for immersive reading (light)")
    func immersiveLight() async {
        verify(await immersiveScreen(), theme: .vellumLight, name: "immersive_light")
    }

    @Test("the immersive (nav-bar-hidden) state renders in the dark theme")
    func immersiveDark() async {
        verify(await immersiveScreen(), theme: .vellumDark, name: "immersive_dark")
    }

    @Test("the immersive (nav-bar-hidden) state renders in the sepia theme")
    func immersiveSepia() async {
        verify(await immersiveScreen(), theme: .sepiaLight, name: "immersive_sepia")
    }

    @Test("the immersive state renders at Dynamic Type XXL (light) — taller bar still clears")
    func immersiveLightXXL() async {
        verify(await immersiveScreen(), theme: .vellumLight, dynamicType: .xxLarge,
               name: "immersive_light_xxl")
    }

    @Test("the immersive state renders at Dynamic Type XXL in the dark theme")
    func immersiveDarkXXL() async {
        verify(await immersiveScreen(), theme: .vellumDark, dynamicType: .xxLarge,
               name: "immersive_dark_xxl")
    }

    @Test("the immersive state renders at Dynamic Type XXL in the sepia theme")
    func immersiveSepiaXXL() async {
        verify(await immersiveScreen(), theme: .sepiaLight, dynamicType: .xxLarge,
               name: "immersive_sepia_xxl")
    }

    /// A `BibleScreen` on 1 Peter 2 driven into immersive mode: a user-driven
    /// downward scroll run past the hide gate flips `isImmersive`, sliding the
    /// nav bar up off screen and fading it out. The reader itself still renders
    /// from the top, so the snapshot captures the chapter with its nav bar gone
    /// — the reclaimed reading space the feature exists to provide.
    private func immersiveScreen() async -> BibleScreen {
        let viewModel = BibleScreenViewModel(
            textLoader: DatabaseBibleTextLoader(),
            initialPosition: BiblePosition(bookId: "1PE", chapterNumber: 2)
        )
        await viewModel.load()
        viewModel.updateScroll(offsetY: 80, userDriven: true)
        viewModel.updateScroll(offsetY: 140, userDriven: true)
        return BibleScreen(viewModel: viewModel)
    }

    // MARK: - Annotations

    @Test("annotation bubbles render after the chapter title and after annotated verses")
    func annotatedLight() async throws {
        verify(try await annotatedScreen(), theme: .vellumLight, name: "annotated_light")
    }

    @Test("annotation bubbles render in the dark theme")
    func annotatedDark() async throws {
        verify(try await annotatedScreen(), theme: .vellumDark, name: "annotated_dark")
    }

    @Test("annotation bubbles render in the sepia theme")
    func annotatedSepia() async throws {
        verify(try await annotatedScreen(), theme: .sepiaLight, name: "annotated_sepia")
    }

    @Test("annotation bubbles render at Dynamic Type XXL")
    func annotatedLightXXL() async throws {
        verify(try await annotatedScreen(), theme: .vellumLight, dynamicType: .xxLarge,
               name: "annotated_light_xxl")
    }

    /// A `BibleScreen` on 1 Peter 2 with one chapter-target annotation
    /// (a bubble next to the title) plus two verse-target rows ending at
    /// distinct verses (bubbles inline after each verse's last word).
    /// Wired to a database context whose `bibleAnnotation` rows the
    /// chapter reader's `@Query<ChapterAnnotationsRequest>` observes.
    private func annotatedScreen() async throws -> some View {
        let database = try BibleDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let repository = GRDBBibleAnnotationRepository(database: database)
        try await repository.replace(
            target: .chapter, bookId: "1PE", chapterNumber: 2,
            verseStart: nil, verseEnd: nil,
            inserting: [
                BibleAnnotationRecord(
                    id: "chap", target: .chapter, bookId: "1PE", chapterNumber: 2,
                    category: .summary, title: "Summary",
                    body: "Peter calls scattered believers a chosen race and royal priesthood.",
                    source: .user, modelId: "afm-3.0", createdAt: now
                )
            ]
        )
        try await repository.replace(
            target: .verse, bookId: "1PE", chapterNumber: 2,
            verseStart: 4, verseEnd: 4,
            inserting: [
                BibleAnnotationRecord(
                    id: "v4", target: .verse, bookId: "1PE",
                    chapterNumber: 2, verseStart: 4, verseEnd: 4,
                    category: .summary, title: "Living stone",
                    body: "Echo of Psalm 118:22 — rejected by men, chosen by God.",
                    source: .user, modelId: "afm-3.0", createdAt: now
                )
            ]
        )
        try await repository.replace(
            target: .verse, bookId: "1PE", chapterNumber: 2,
            verseStart: 9, verseEnd: 9,
            inserting: [
                BibleAnnotationRecord(
                    id: "v9", target: .verse, bookId: "1PE",
                    chapterNumber: 2, verseStart: 9, verseEnd: 9,
                    category: .summary, title: "Royal priesthood",
                    body: "Drawn from Exodus 19:5-6 — Israel's identity language extended to the church.",
                    source: .user, modelId: "afm-3.0", createdAt: now
                )
            ]
        )
        let viewModel = BibleScreenViewModel(
            textLoader: DatabaseBibleTextLoader(),
            initialPosition: BiblePosition(bookId: "1PE", chapterNumber: 2)
        )
        await viewModel.load()
        return BibleScreen(viewModel: viewModel, annotationRepository: repository)
            .databaseContext(.readOnly { database.queue })
    }

    // MARK: - Narration overlay

    @Test("narration underlines the active verse in the reader (light)")
    func narratingLight() async {
        verify(await narratingScreen(currentVerse: 4),
               theme: .vellumLight, name: "narrating_light")
    }

    @Test("the active-verse underline renders in the dark theme")
    func narratingDark() async {
        verify(await narratingScreen(currentVerse: 4),
               theme: .vellumDark, name: "narrating_dark")
    }

    @Test("the active-verse underline renders in the sepia theme")
    func narratingSepia() async {
        verify(await narratingScreen(currentVerse: 4),
               theme: .sepiaLight, name: "narrating_sepia")
    }

    @Test("the active-verse underline renders at Dynamic Type XXL")
    func narratingLightXXL() async {
        verify(await narratingScreen(currentVerse: 4),
               theme: .vellumLight, dynamicType: .xxLarge,
               name: "narrating_light_xxl")
    }

    @Test("the active-verse underline renders at Dynamic Type XXL in the dark theme")
    func narratingDarkXXL() async {
        verify(await narratingScreen(currentVerse: 4),
               theme: .vellumDark, dynamicType: .xxLarge,
               name: "narrating_dark_xxl")
    }

    @Test("the active-verse underline renders at Dynamic Type XXL in the sepia theme")
    func narratingSepiaXXL() async {
        verify(await narratingScreen(currentVerse: 4),
               theme: .sepiaLight, dynamicType: .xxLarge,
               name: "narrating_sepia_xxl")
    }

    /// Pins the dashed narration rule at the same 1pt floor as selection when
    /// the slider is at 0.8× (both share `underlineWeight`).
    @Test("the active-verse dashed underline thins to its 1pt floor at the min font scale")
    func narratingFontScaleMinLight() async {
        verify(await narratingScreen(currentVerse: 4),
               theme: .vellumLight, fontScale: 0.8,
               name: "narrating_font_scale_min_light")
    }

    /// A `BibleScreen` whose narration controller is driven into
    /// `.speaking` on `currentVerse`. The fake service lets the test
    /// hold the controller in that state for the snapshot without
    /// invoking the real `AVSpeechSynthesizer`. The transport card itself
    /// presents as a native `.sheet` (not captured here); this snapshot
    /// covers the reader-side active-verse underline.
    ///
    /// Drives the `.started` event via `NarrationController
    /// ._simulateEvent(_:)` rather than the fake's `AsyncStream` so the
    /// state transition is deterministic, per root AGENTS.md §
    /// Testing.2.
    private func narratingScreen(currentVerse: Int) async -> BibleScreen {
        let service = FakeNarrationService()
        let narration = NarrationController(service: service)
        let viewModel = BibleScreenViewModel(
            textLoader: DatabaseBibleTextLoader(),
            initialPosition: BiblePosition(bookId: "1PE", chapterNumber: 2),
            narration: narration
        )
        await viewModel.load()
        viewModel.startNarration()
        narration._simulateEvent(.started(verseNumber: currentVerse))
        return BibleScreen(viewModel: viewModel)
    }

    /// A `BibleScreen` over the real bundled text, loaded to `position`.
    private func screen(at position: BiblePosition) async -> BibleScreen {
        let viewModel = BibleScreenViewModel(
            textLoader: DatabaseBibleTextLoader(),
            initialPosition: position
        )
        await viewModel.load()
        return BibleScreen(viewModel: viewModel)
    }

    /// A `BibleScreen` on 1 Peter 2 with verses 4-6 and 9 selected.
    private func selectionScreen() async -> BibleScreen {
        let viewModel = BibleScreenViewModel(
            textLoader: DatabaseBibleTextLoader(),
            initialPosition: BiblePosition(bookId: "1PE", chapterNumber: 2)
        )
        await viewModel.load()
        for verse in [4, 5, 6, 9] { viewModel.toggleVerse(verse) }
        return BibleScreen(viewModel: viewModel)
    }

    /// A `BibleScreen` on 1 Peter 2 with the chat "coming soon" toast raised.
    private func toastScreen() async -> BibleScreen {
        let viewModel = BibleScreenViewModel(
            textLoader: DatabaseBibleTextLoader(),
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
            textLoader: DatabaseBibleTextLoader(),
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
        fontScale: CGFloat = 1,
        name: String,
        function: String = #function
    ) {
        let view = screen
            .superTheme(.make(theme))
            .superTypography(.make(.serif, fontScale: fontScale))
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
