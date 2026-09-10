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

    @Test("history states keep independent disabled controls without changing layout")
    func historyStatesGallery() {
        let states: [(String?, String?)] = [(nil, nil), (nil, "Psalm 23"), ("John 3", "Psalm 23"), ("John 3", nil)]
        let books = ["John", "2 Chronicles", "1 Corinthians", "2 Thessalonians"]
        let view = VStack(spacing: 0) {
            ForEach(states.indices, id: \.self) { index in
                bar(bookName: books[index], showsChapterChevrons: false, history: .init(
                    backLabel: states[index].0, forwardLabel: states[index].1,
                    onBack: {}, onForward: {}
                ))
            }
        }
        .frame(width: 402, height: 320, alignment: .top)
        .background(SuperTheme.make(.vellumLight).background)
        .superTheme(.make(.vellumLight))
        let failure = verifyVisualSnapshot(
            of: view, as: .image(layout: .fixed(width: 402, height: 320)),
            named: "history_states", testName: #function
        )
        if let failure { Issue.record("\(failure)") }
    }

    @Test("long names and accessibility text fit below utility controls on narrow screens")
    func historyNarrowAccessibility() {
        let view = bar(bookName: "Song of Solomon", showsChapterChevrons: true)
            .frame(width: 320, height: 360, alignment: .top)
            .background(SuperTheme.make(.vellumLight).background)
            .dynamicTypeSize(.accessibility3)
            .superFontScale(1.5)
            .superTheme(.make(.vellumLight))
        let failure = verifyVisualSnapshot(
            of: view, as: .image(layout: .fixed(width: 320, height: 360)),
            named: "history_narrow_accessibility", testName: #function
        )
        if let failure { Issue.record("\(failure)") }
    }

    @Test("ordinary long book names fit in the primary row on a compact iPhone", arguments: ["2 Corinthians", "2 Thessalonians"])
    func longNamesStayInPrimaryRow(book: String) {
        let host = UIHostingController(rootView: bar(bookName: book, showsChapterChevrons: false)
            .superTheme(.make(.vellumLight)))
        let size = host.sizeThatFits(in: CGSize(width: 375, height: 1000))
        #expect(size.height < 100, "A second toolbar row exceeds the single-row height budget")
    }

    @Test("the selector hugs short content and grows only to fit a longer passage")
    func selectorHugsContent() {
        let short = UIHostingController(rootView: SelectorSizeProbe(book: "John"))
            .sizeThatFits(in: CGSize(width: 375, height: 1000))
        let long = UIHostingController(rootView: SelectorSizeProbe(book: "2 Corinthians"))
            .sizeThatFits(in: CGSize(width: 375, height: 1000))
        #expect(long.width > short.width + 30)
        #expect(long.width <= 231, "Leave room for both 44pt utility buttons and the toolbar gaps")
        #expect(short.height >= 44)
    }

    private struct SelectorSizeProbe: View {
        @Namespace private var namespace
        let book: String

        var body: some View {
            BibleNavigationSelector(
                bookName: book, chapterNumber: 13, translation: .web,
                backLabel: nil, forwardLabel: nil, wraps: false, isRestoring: false,
                morph: GlassMorphID("probe", in: namespace), onBack: {}, onForward: {}, onSelect: {}
            )
            .fixedSize()
            .superTheme(.make(.vellumLight))
        }
    }

    private func bar(
        bookName: String = "1 Peter",
        canStepBackward: Bool = true,
        canStepForward: Bool = true,
        selectionCitation: String? = nil,
        showsChapterChevrons: Bool = true,
        narrationState: NarrationController.State = .idle,
        narrationCitation: String? = nil,
        history: BibleNavBar.HistoryControls = .init(
            backLabel: "John 3", forwardLabel: "Psalm 23", onBack: {}, onForward: {}
        )
    ) -> BibleNavBar {
        BibleNavBar(
            bookName: bookName, chapterNumber: 2, translation: .web,
            selectionCitation: selectionCitation, showsSelectionPill: showsChapterChevrons,
            showsChapterChevrons: showsChapterChevrons,
            canStepBackward: canStepBackward, canStepForward: canStepForward,
            narrationState: narrationState, narrationCitation: narrationCitation,
            onPrevious: {}, onNext: {}, onPill: {},
            onSelectionPill: {}, onClearSelection: {}, onSparkMenuAction: { _ in },
            onTapNarrationPill: {}, historyControls: history
        )
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
            bar(
                canStepBackward: canStepBackward, canStepForward: canStepForward,
                selectionCitation: selectionCitation, showsChapterChevrons: showsChapterChevrons,
                narrationState: narrationState, narrationCitation: narrationCitation
            )
        }
        .frame(width: 402, height: 160)
        .superTheme(theme)

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 160)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
