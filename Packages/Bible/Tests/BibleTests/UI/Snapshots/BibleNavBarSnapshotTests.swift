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

    @Test("reading mode navigation stays centered across the iPad window")
    func readingModesGallery() {
        let view = VStack(spacing: 0) {
            ForEach([SuperTheme.Identifier.vellumLight, .vellumDark], id: \.self) { theme in
                VStack(spacing: 0) {
                    ForEach(BibleReadingMode.allCases) { mode in
                        bar(bookName: "Song of Solomon", showsChapterChevrons: false,
                            readingMode: mode, centersNavigation: true)
                    }
                }
                .superTheme(.make(theme))
                .background(SuperTheme.make(theme).background)
            }
        }
        .superTypography(.make(.serif, fontScale: 1.2))
        .frame(width: 1024, height: 384, alignment: .top)
        let failure = verifyVisualSnapshot(
            of: view, as: .image(layout: .fixed(width: 1024, height: 384)),
            named: "reading_modes", testName: #function
        )
        if let failure { Issue.record("\(failure)") }
    }

    @Test("centered navigation reserves the hamburger row when a narrow window needs reflow",
          arguments: [DynamicTypeSize.large, .accessibility3, .accessibility5], [320.0, 1024.0])
    func centeredLayoutFits(typeSize: DynamicTypeSize, width: Double) {
        for mode in BibleReadingMode.allCases {
            let view = bar(bookName: "Song of Solomon", showsChapterChevrons: false,
                           readingMode: mode, centersNavigation: true)
                .dynamicTypeSize(typeSize)
                .superTypography(.make(.serif, fontScale: 1.2))
                .superTheme(.make(.vellumLight))
            let size = UIHostingController(rootView: view)
                .sizeThatFits(in: CGSize(width: width, height: 1000))
            #expect(size.width <= width)
            #expect(size.height < (width == 320 ? 480 : 200))
            if width == 320 {
                #expect(size.height >= 104, "The navigation row must clear the shell's 44-point hamburger")
            } else if typeSize == .large {
                #expect(abs(size.height - 60) < 0.5)
            }
        }
    }

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

    @Test("the chevron-less bar anchors the pill beside the sidebar button in the light theme")
    func noChevronsLight() {
        verify(theme: .vellumLight, canStepBackward: true, canStepForward: true,
               name: "no_chevrons_light", showsChapterChevrons: false)
    }

    @Test("the chevron-less bar anchors the pill beside the sidebar button in the dark theme")
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

    // MARK: - Narration states

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

    @Test("the ellipsis keeps the selection indicator while narration remains available")
    func narratingSpeakerButtonWithSelectionDotLight() {
        verify(theme: .vellumLight, canStepBackward: true, canStepForward: true,
               name: "narrating_speaker_button_with_selection_light",
               selectionCitation: "1 Peter 2:4-6, 9",
               narrationState: .speaking, narrationCitation: "1 Peter 2:4")
    }

    @Test("history states keep independent disabled controls without changing layout")
    func historyStatesGallery() {
        let states: [(String?, String?)] = [(nil, nil), (nil, "Psalm 23"), ("John 3", "Psalm 23"), ("John 3", nil)]
        let books = ["John", "2 Chronicles", "1 Corinthians", "Song of Solomon"]
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

    @Test("the anchored bar keeps accessibility text clear of fixed controls")
    func anchoredNarrowAccessibility() {
        let view = bar(bookName: "Song of Solomon", showsChapterChevrons: false)
            .dynamicTypeSize(.accessibility3)
            .superTypography(.make(.serif, fontScale: 1.2))
            .superTheme(.make(.vellumLight))
        let size = UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: 320, height: 1000))
        #expect(size.width <= 320)
        #expect(size.height < 360)
        let failure = verifyVisualSnapshot(
            of: view.frame(width: 320, height: 360, alignment: .top)
                .background(SuperTheme.make(.vellumLight).background),
            as: .image(layout: .fixed(width: 320, height: 360)),
            named: "anchored_narrow_accessibility", testName: #function
        )
        if let failure { Issue.record("\(failure)") }
    }

    @Test("the largest accessibility text fits without crowding navigation controls")
    func largestAccessibility() {
        let view = bar(bookName: "Song of Solomon", showsChapterChevrons: false)
            .dynamicTypeSize(.accessibility5)
            .superTypography(.make(.serif, fontScale: 1.2))
            .superTheme(.make(.vellumLight))
        let size = UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: 320, height: 1000))
        #expect(size.width <= 320)
        #expect(size.height < 480)
        let failure = verifyVisualSnapshot(
            of: view.frame(width: 320, height: 480, alignment: .top)
                .background(SuperTheme.make(.vellumLight).background),
            as: .image(layout: .fixed(width: 320, height: 480)),
            named: "largest_accessibility", testName: #function
        )
        if let failure { Issue.record("\(failure)") }
    }

    @Test("large accessibility layouts fit compact screens and keep a single row on wide screens",
          arguments: [DynamicTypeSize.accessibility4, .accessibility5], [320.0, 1024.0])
    func accessibilityLayoutFits(typeSize: DynamicTypeSize, width: Double) {
        let view = bar(bookName: "Song of Solomon", showsChapterChevrons: false)
            .dynamicTypeSize(typeSize)
            .superTypography(.make(.serif, fontScale: 1.2))
            .superTheme(.make(.vellumLight))
        let size = UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: width, height: 1000))
        #expect(size.width <= width)
        #expect(size.height < (width == 320 ? 480 : 200))
    }

    @Test("long book names fit in the primary row on compact iPhones",
          arguments: ["2 Corinthians", "2 Thessalonians", "Song of Solomon"], [320.0, 375.0])
    func longNamesStayInPrimaryRow(book: String, width: Double) {
        let host = UIHostingController(rootView: bar(bookName: book, showsChapterChevrons: false)
            .superTheme(.make(.vellumLight)))
        let size = host.sizeThatFits(in: CGSize(width: width, height: 1000))
        #expect(size.height < 100, "A second toolbar row exceeds the single-row height budget")
    }

    @Test("the combined pill matches the hamburger height", arguments: ["John", "2 Thessalonians", "Song of Solomon"])
    func navigationMatchesHamburgerHeight(book: String) {
        for fontScale in [1.0, 1.5] {
            let host = UIHostingController(rootView: bar(bookName: book, showsChapterChevrons: false)
                .superTheme(.make(.vellumLight))
                .superTypography(.make(.serif, fontScale: fontScale)))
            let size = host.sizeThatFits(in: CGSize(width: 375, height: 1000))
            #expect(abs(size.height - 60) < 0.5, "44-point controls plus 16 points of vertical padding")
        }
    }

    @Test("height fitting preserves the pill aspect ratio as its content size changes")
    func pillPreservesAspectRatio() {
        let host = UIHostingController(rootView: PillSizeProbe(size: CGSize(width: 280, height: 50)))
        for natural in [
            CGSize(width: 280, height: 50), CGSize(width: 420, height: 90),
            CGSize(width: 280, height: 50), CGSize(width: 160, height: 40),
        ] {
            host.rootView = PillSizeProbe(size: natural)
            let fitted = host.sizeThatFits(in: CGSize(width: 1000, height: 1000))
            #expect(abs(fitted.height - min(natural.height, 44)) < 0.5)
            #expect(abs(fitted.width / fitted.height - natural.width / natural.height) < 0.02)
        }
    }

    private struct PillSizeProbe: View {
        @Namespace private var glassNamespace
        let size: CGSize

        var body: some View {
            BibleNavigationPill(morph: GlassMorphID("test.pill", in: glassNamespace)) {
                Color.clear.frame(width: size.width, height: size.height)
            }
        }
    }

    @Test("long selection citations fit within the available fallback width")
    func longSelectionFitsAvailableWidth() {
        let host = UIHostingController(rootView: LongSelectionPillProbe())
        let fitted = host.sizeThatFits(in: CGSize(width: 220, height: 1000))
        #expect(fitted.width <= 220)
        #expect(abs(fitted.height - 44) < 0.5)
    }

    private struct LongSelectionPillProbe: View {
        @Namespace private var glassNamespace

        var body: some View {
            BibleNavigationPill(morph: GlassMorphID("test.selection", in: glassNamespace)) {
                HStack(spacing: 0) {
                    Text("Psalm 119:1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25")
                        .font(SuperTypography.make(.serif).font(size: 13, weight: .semibold))
                        .padding(8)
                        .frame(minHeight: 44)
                    Color.clear.frame(width: 120, height: 44)
                }
            }
        }
    }

    @Test("passages share the p90 preferred book width")
    func selectorUsesP90BookWidth() {
        let short = UIHostingController(rootView: SelectorSizeProbe(book: "John"))
            .sizeThatFits(in: CGSize(width: 375, height: 1000))
        let shorter = UIHostingController(rootView: SelectorSizeProbe(book: "Job"))
            .sizeThatFits(in: CGSize(width: 375, height: 1000))
        let medium = UIHostingController(rootView: SelectorSizeProbe(book: "Revelation"))
            .sizeThatFits(in: CGSize(width: 375, height: 1000))
        let wrapping = UIHostingController(rootView: SelectorSizeProbe(book: "John", wraps: true))
            .sizeThatFits(in: CGSize(width: 375, height: 1000))
        let long = UIHostingController(rootView: SelectorSizeProbe(book: "2 Thessalonians"))
            .sizeThatFits(in: CGSize(width: 375, height: 1000))
        let nameWidths = BibleBookCatalog.standard.books.map { labelWidth($0.name) }.sorted()
        let percentileIndex = Int(ceil(0.9 * Double(nameWidths.count))) - 1
        let preferredLabelWidth = ceil(nameWidths[percentileIndex] + labelWidth(" 12"))
        #expect(abs(short.width - shorter.width) < 1)
        #expect(abs(short.width - medium.width) < 1)
        #expect(abs(short.width - wrapping.width) < 1)
        #expect(abs(short.width - (65 + 16 + preferredLabelWidth)) < 1)
        #expect(abs(long.width - short.width) < 1)
        #expect(long.width <= 231, "Leave room for narration, actions, and the sidebar")
        #expect(short.height >= 44)
    }

    @Test("the passage expands or compresses to the available width",
          arguments: ["John", "Song of Solomon"], [150.0, 250.0])
    func selectorFitsAvailableWidth(book: String, width: Double) {
        let host = UIHostingController(rootView: SelectorSizeProbe(book: book, usesIdealWidth: false))
        let size = host.sizeThatFits(in: CGSize(width: width, height: 1000))
        #expect(abs(size.width - width) < 1)
        #expect(size.height < 60)
    }

    @Test("the selector preferred width tracks app font scaling once and grows with Dynamic Type")
    func selectorPreferredWidthTracksFontScaling() {
        let base = UIHostingController(rootView: SelectorSizeProbe(book: "Job"))
            .sizeThatFits(in: CGSize(width: 1000, height: 1000))
        let scaled = UIHostingController(rootView: SelectorSizeProbe(book: "Job")
            .superTypography(.make(.serif, fontScale: 1.2)))
            .sizeThatFits(in: CGSize(width: 1000, height: 1000))
        let dynamic = UIHostingController(rootView: SelectorSizeProbe(book: "Job").dynamicTypeSize(.xxLarge))
            .sizeThatFits(in: CGSize(width: 1000, height: 1000))
        // History, its divider, and horizontal padding do not scale with the label.
        let fixedChromeWidth: CGFloat = 65 + 16
        #expect(abs((scaled.width - fixedChromeWidth) - (base.width - fixedChromeWidth) * 1.2) < 1)
        #expect(dynamic.width > base.width + 10)
    }

    private func labelWidth(_ label: String) -> CGFloat {
        UIHostingController(rootView: Text(label)
            .font(SuperTypography.make(.serif).font(size: 14, weight: .medium))
            .fixedSize())
            .sizeThatFits(in: CGSize(width: 1000, height: 1000)).width
    }

    private struct SelectorSizeProbe: View {
        let book: String
        var wraps = false
        var usesIdealWidth = true

        var body: some View {
            BibleNavigationSelector(
                bookName: book, chapterNumber: 13, translation: .web,
                backLabel: nil, forwardLabel: nil, wraps: wraps, isRestoring: false,
                onBack: {}, onForward: {}, onSelect: {}
            )
            .fixedSize(horizontal: usesIdealWidth, vertical: true)
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
        readingMode: BibleReadingMode? = nil,
        centersNavigation: Bool = false,
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
            onSelectionPill: {}, onClearSelection: {}, onMenuAction: { _ in },
            onNarration: {}, historyControls: history,
            readingMode: readingMode, onCycleReadingMode: {}, centersNavigation: centersNavigation
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
