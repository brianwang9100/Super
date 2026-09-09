#if canImport(UIKit)
import Core
import Foundation
import GRDBQuery
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Bible

/// Native sheets need separate content captures: the snapshotter's single layout
/// pass only captures reader decorations. Sheet-specific suites cover their contents.
@Suite("BibleScreen snapshots", .serialized)
@MainActor
struct BibleScreenSnapshotTests {
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

    @Test("1 Peter 2 renders in the light theme at Dynamic Type XXL")
    func populatedLightXXL() async throws {
        verify(await screen(at: BiblePosition(bookId: "1PE", chapterNumber: 2)),
               theme: .vellumLight, dynamicType: .xxLarge, name: "populated_light_xxl")
    }

    @Test("1 Peter 2 scales with the app font-scale slider at max in the light theme")
    func populatedFontScaleMaxLight() async throws {
        verify(await screen(at: BiblePosition(bookId: "1PE", chapterNumber: 2)),
               theme: .vellumLight, fontScale: 1.2, name: "populated_font_scale_max_light")
    }

    @Test("1 Peter 2 scales with the app font-scale slider at min in the light theme")
    func populatedFontScaleMinLight() async throws {
        verify(await screen(at: BiblePosition(bookId: "1PE", chapterNumber: 2)),
               theme: .vellumLight, fontScale: 0.8, name: "populated_font_scale_min_light")
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
        for dismissActions in [false, true] {
            verify(await selectionScreen(dismissActions: dismissActions),
                   theme: .vellumLight, name: "selection_active_light" + (dismissActions ? "-dismissed" : ""),
                   context: "dismissActions: \(dismissActions)")
        }
    }

    @Test("verse selection renders in the dark theme")
    func selectionActiveDark() async {
        for dismissActions in [false, true] {
            verify(await selectionScreen(dismissActions: dismissActions),
                   theme: .vellumDark, name: "selection_active_dark" + (dismissActions ? "-dismissed" : ""),
                   context: "dismissActions: \(dismissActions)")
        }
    }

    @Test("verse selection renders in the light theme at Dynamic Type XXL")
    func selectionActiveLightXXL() async {
        verify(await selectionScreen(),
               theme: .vellumLight, dynamicType: .xxLarge,
               name: "selection_active_light_xxl")
    }

    /// One theme suffices for the theme-independent 1pt underline floor.
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

    @Test("the chat toast renders in the light theme at Dynamic Type XXL")
    func chatToastLightXXL() async {
        verify(await toastScreen(), theme: .vellumLight, dynamicType: .xxLarge,
               name: "chat_toast_light_xxl")
    }

    @Test("persisted highlights paint their verses in the light theme")
    func highlightedLight() async throws {
        verify(try await highlightedScreen(), theme: .vellumLight, name: "highlighted_light")
    }

    @Test("persisted highlights render in the dark theme")
    func highlightedDark() async throws {
        verify(try await highlightedScreen(), theme: .vellumDark, name: "highlighted_dark")
    }

    @Test("persisted highlights render in the light theme at Dynamic Type XXL")
    func highlightedLightXXL() async throws {
        verify(try await highlightedScreen(), theme: .vellumLight, dynamicType: .xxLarge,
               name: "highlighted_light_xxl")
    }

    // At minimum font scale, raised verse numbers previously made highlight bands taller than neighboring words.
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

    // MARK: - Immersive reading (scroll-hidden nav bar)

    @Test("scrolling down hides the nav bar for immersive reading (light)")
    func immersiveLight() async {
        verify(await immersiveScreen(), theme: .vellumLight, name: "immersive_light")
    }

    @Test("the immersive state renders at Dynamic Type XXL (light) — taller bar still clears")
    func immersiveLightXXL() async {
        verify(await immersiveScreen(), theme: .vellumLight, dynamicType: .xxLarge,
               name: "immersive_light_xxl")
    }

    /// Forces immersive state without moving the reader, isolating the reclaimed toolbar space.
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

    @Test("annotation bubbles render at Dynamic Type XXL")
    func annotatedLightXXL() async throws {
        verify(try await annotatedScreen(), theme: .vellumLight, dynamicType: .xxLarge,
               name: "annotated_light_xxl")
    }

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
                    summary: "Summary — Peter calls scattered believers a chosen race and royal priesthood.",
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
                    summary: "Living stone — Echo of Psalm 118:22 — rejected by men, chosen by God.",
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
                    summary: "Royal priesthood — Drawn from Exodus 19:5-6 — Israel's identity language extended to the church.",
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

    @Test("the active-verse underline renders at Dynamic Type XXL")
    func narratingLightXXL() async {
        verify(await narratingScreen(currentVerse: 4),
               theme: .vellumLight, dynamicType: .xxLarge,
               name: "narrating_light_xxl")
    }

    /// Shares the selection underline's 1pt floor at minimum font scale.
    @Test("the active-verse dashed underline thins to its 1pt floor at the min font scale")
    func narratingFontScaleMinLight() async {
        verify(await narratingScreen(currentVerse: 4),
               theme: .vellumLight, fontScale: 0.8,
               name: "narrating_font_scale_min_light")
    }

    // Apply the event synchronously so the capture cannot race stream consumption.
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

    private func screen(at position: BiblePosition) async -> BibleScreen {
        let viewModel = BibleScreenViewModel(
            textLoader: DatabaseBibleTextLoader(),
            initialPosition: position
        )
        await viewModel.load()
        return BibleScreen(viewModel: viewModel)
    }

    /// Dismissing actions must preserve the citation and underline baseline.
    private func selectionScreen(dismissActions: Bool = false) async -> BibleScreen {
        let viewModel = BibleScreenViewModel(
            textLoader: DatabaseBibleTextLoader(),
            initialPosition: BiblePosition(bookId: "1PE", chapterNumber: 2)
        )
        await viewModel.load()
        for verse in [4, 5, 6, 9] { viewModel.toggleVerse(verse) }
        if dismissActions { viewModel.dismissActionSheet() }
        return BibleScreen(viewModel: viewModel)
    }

    private func toastScreen() async -> BibleScreen {
        let viewModel = BibleScreenViewModel(
            textLoader: DatabaseBibleTextLoader(),
            initialPosition: BiblePosition(bookId: "1PE", chapterNumber: 2)
        )
        await viewModel.load()
        viewModel.presentChatComingSoon()
        return BibleScreen(viewModel: viewModel)
    }

    private func unavailableScreen() async -> BibleScreen {
        let viewModel = BibleScreenViewModel(textLoader: ThrowingBibleTextLoader())
        await viewModel.load()
        return BibleScreen(viewModel: viewModel)
    }

    // Keep all three highlight colors above the captured frame's fold.
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
        function: String = #function,
        context: String = ""
    ) {
        let view = screen
            .superTheme(.make(theme))
            .superTypography(.make(.serif, fontScale: fontScale))
            .dynamicTypeSize(dynamicType)
            .frame(width: 402, height: 760)

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 760)),
            named: name,
            testName: function
        )
        if let failure {
            let label = context.isEmpty ? name : "\(name) (\(context))"
            Issue.record("\(label): \(failure)")
        }
    }
}
#endif
