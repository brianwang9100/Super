#if canImport(UIKit)
import Core
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Bible

@Suite("BibleNavBar snapshots", .serialized)
@MainActor
struct BibleNavBarSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("the nav bar renders in the light theme")
    func defaultLight() {
        verify(theme: .vellumLight, canStepBackward: true, canStepForward: true, name: "default_light")
    }

    @Test("the nav bar renders in the dark theme")
    func defaultDark() {
        verify(theme: .vellumDark, canStepBackward: true, canStepForward: true, name: "default_dark")
    }

    @Test("the previous arrow is disabled at the start of the canon")
    func previousDisabled() {
        verify(theme: .vellumLight, canStepBackward: false, canStepForward: true,
               name: "previous_disabled_light")
    }

    @Test("the next arrow is disabled at the end of the canon")
    func nextDisabled() {
        verify(theme: .vellumLight, canStepBackward: true, canStepForward: false,
               name: "next_disabled_light")
    }

    @Test("selection mode collapses the centre group to a citation pill")
    func selectionLight() {
        verify(theme: .vellumLight, canStepBackward: true, canStepForward: true,
               name: "selection_light", selectionCitation: "1 Peter 2:4-6, 9")
    }

    @Test("selection mode renders in the dark theme")
    func selectionDark() {
        verify(theme: .vellumDark, canStepBackward: true, canStepForward: true,
               name: "selection_dark", selectionCitation: "1 Peter 2:4-6, 9")
    }

    // MARK: - Chevron-less form

    @Test("the chevron-less bar centres the pill in the light theme")
    func noChevronsLight() {
        verify(theme: .vellumLight, canStepBackward: true, canStepForward: true,
               name: "no_chevrons_light", showsChapterChevrons: false)
    }

    @Test("the chevron-less bar centres the pill in the dark theme")
    func noChevronsDark() {
        verify(theme: .vellumDark, canStepBackward: true, canStepForward: true,
               name: "no_chevrons_dark", showsChapterChevrons: false)
    }

    @Test("bottom selection controls leave the top chapter picker and selection indicator (light)")
    func bottomSelectionLight() {
        verify(theme: .vellumLight, canStepBackward: true, canStepForward: true,
               name: "bottom_selection_light", selectionCitation: "1 Peter 2:4-6, 9",
               showsChapterChevrons: false)
    }

    @Test("bottom selection controls leave the top chapter picker and selection indicator (dark)")
    func bottomSelectionDark() {
        verify(theme: .vellumDark, canStepBackward: true, canStepForward: true,
               name: "bottom_selection_dark", selectionCitation: "1 Peter 2:4-6, 9",
               showsChapterChevrons: false)
    }

    // MARK: - Narration trailing-control states

    @Test("the narration speaker button renders in the light theme while speaking")
    func narratingSpeakerButtonSpeakingLight() {
        verify(theme: .vellumLight, canStepBackward: true, canStepForward: true,
               name: "narrating_speaker_button_speaking_light",
               narrationState: .speaking, narrationCitation: "1 Peter 2:9")
    }

    @Test("the narration speaker button renders in the dark theme while speaking")
    func narratingSpeakerButtonSpeakingDark() {
        verify(theme: .vellumDark, canStepBackward: true, canStepForward: true,
               name: "narrating_speaker_button_speaking_dark",
               narrationState: .speaking, narrationCitation: "1 Peter 2:9")
    }

    @Test("the narration speaker button renders the paused state")
    func narratingSpeakerButtonPausedLight() {
        verify(theme: .vellumLight, canStepBackward: true, canStepForward: true,
               name: "narrating_speaker_button_paused_light",
               narrationState: .paused, narrationCitation: "1 Peter 2:9")
    }

    @Test("the narration speaker button keeps the red selection dot when verses are selected")
    func narratingSpeakerButtonWithSelectionDotLight() {
        verify(theme: .vellumLight, canStepBackward: true, canStepForward: true,
               name: "narrating_speaker_button_with_selection_light",
               selectionCitation: "1 Peter 2:4-6, 9",
               narrationState: .speaking, narrationCitation: "1 Peter 2:4")
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        canStepBackward: Bool,
        canStepForward: Bool,
        name: String,
        selectionCitation: String? = nil,
        showsChapterChevrons: Bool = true,
        narrationState: NarrationController.State = .idle,
        narrationCitation: String? = nil,
        function: String = #function
    ) {
        let theme = SuperTheme.make(themeID)
        let view = ZStack(alignment: .top) {
            theme.background
            BibleNavBar(
                bookName: "1 Peter",
                chapterNumber: 2,
                translation: .web,
                selectionCitation: selectionCitation,
                showsSelectionPill: showsChapterChevrons,
                showsChapterChevrons: showsChapterChevrons,
                canStepBackward: canStepBackward,
                canStepForward: canStepForward,
                narrationState: narrationState,
                narrationCitation: narrationCitation,
                onPrevious: {},
                onNext: {},
                onPill: {},
                onTranslation: {},
                onSelectionPill: {},
                onClearSelection: {},
                onSparkMenuAction: { _ in },
                onTapNarrationPill: {}
            )
        }
        .frame(width: 402, height: 96)
        .superTheme(theme)

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 96)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
