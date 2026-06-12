#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `AnnotationBlock` — the single stateless study card
/// rendered inside `AnnotationSheet`. Variants cover the three target
/// shapes (verse range with quoted text, chapter, book — the latter two
/// omit the verse-text region), a long markdown summary exercising the
/// shared renderer's block chrome (headings, bold, bullets, blockquote,
/// auto-linkified citation), and a Dynamic Type XXL pass because the
/// summary prose reflows.
@Suite("AnnotationBlock snapshots")
@MainActor
struct AnnotationBlockSnapshotTests {
    /// Register Core's bundled brand fonts so the migrated JetBrains Mono /
    /// EB Garamond chrome faces resolve instead of baking the system
    /// fallback, and so this suite stays order-independent (registration is
    /// process-global; see `SnapshotFontRegistration`).
    init() { SnapshotFontRegistration.ensureRegistered() }

    private static let verseText = """
    We know that all things work together for good for those who love \
    God, for those who are called according to his purpose.
    """

    private static let shortSummary = """
    ### Plain meaning
    Nothing — pain, loss, even death — falls outside what God can weave \
    toward the believer's good. **"Good"** here means conformity to \
    Christ, not pleasant circumstances.
    """

    /// Long-form markdown exercising every renderer path the dispatcher
    /// contract asks for: `###` headings, bold key terms, a bullet list,
    /// a blockquote, and a full-book-name citation (`Hebrews 4:15`) that
    /// the shared renderer auto-linkifies into a `super://bible/...` link.
    private static let longSummary = """
    ### Plain meaning
    Paul is not promising that everything will feel good, only that \
    nothing falls outside of what God can weave toward our good. \
    **"Good"** means conformity to Christ, not pleasant circumstances. \
    The cross is the pattern.

    ### Context
    "All things" includes the suffering Paul names earlier in the \
    chapter — creation's groaning, the believer's weakness in prayer, \
    even persecution. The chain that follows is deliberate:

    - **Foreknown** — loved beforehand
    - **Predestined** — destined to be conformed to the Son
    - **Called, justified, glorified** — each link already certain

    > There is a long tradition of reading this verse as a comfort to \
    the suffering, but Calvin pushes back: it is a promise about where \
    history is going, not about how the road feels.

    ### Cross-references
    The sympathy of the exalted Christ in Hebrews 4:15 grounds the same \
    assurance: the one who intercedes has shared the weakness he now \
    carries his people through.
    """

    @Test("verse-range card renders quoted text + summary in the light theme")
    func verseRangeLight() {
        verify(
            theme: .vellumLight,
            title: "Romans 8:28-30",
            verseText: Self.verseText,
            summary: Self.shortSummary,
            height: 460,
            name: "verse_range_light"
        )
    }

    @Test("verse-range card renders quoted text + summary in the dark theme")
    func verseRangeDark() {
        verify(
            theme: .vellumDark,
            title: "Romans 8:28-30",
            verseText: Self.verseText,
            summary: Self.shortSummary,
            height: 460,
            name: "verse_range_dark"
        )
    }

    @Test("long markdown summary renders headings, bold, bullets, blockquote, and a linkified citation in light")
    func longSummaryLight() {
        verify(
            theme: .vellumLight,
            title: "Romans 8:28-30",
            verseText: Self.verseText,
            summary: Self.longSummary,
            height: 1240,
            name: "long_summary_light"
        )
    }

    @Test("long markdown summary renders in the dark theme")
    func longSummaryDark() {
        verify(
            theme: .vellumDark,
            title: "Romans 8:28-30",
            verseText: Self.verseText,
            summary: Self.longSummary,
            height: 1240,
            name: "long_summary_dark"
        )
    }

    @Test("chapter card omits the verse-text region")
    func chapterLight() {
        verify(
            theme: .vellumLight,
            title: "Romans 8",
            verseText: nil,
            summary: Self.shortSummary,
            height: 340,
            name: "chapter_light"
        )
    }

    @Test("book card omits the verse-text region")
    func bookLight() {
        verify(
            theme: .vellumLight,
            title: "Romans",
            verseText: nil,
            summary: Self.shortSummary,
            height: 340,
            name: "book_light"
        )
    }

    @Test("verse-range card reflows its prose at Dynamic Type XXL")
    func verseRangeLightXXL() {
        verify(
            theme: .vellumLight,
            title: "Romans 8:28-30",
            verseText: Self.verseText,
            summary: Self.shortSummary,
            height: 640,
            dynamicType: .xxLarge,
            name: "verse_range_light_xxl"
        )
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        title: String,
        verseText: String?,
        summary: String,
        height: CGFloat,
        dynamicType: DynamicTypeSize = .large,
        name: String,
        function: String = #function
    ) {
        let theme = SuperTheme.make(themeID)
        let view = ZStack(alignment: .top) {
            theme.background
            AnnotationBlock(
                title: title,
                verseText: verseText,
                summary: summary,
                provenance: "Generated by AFM 3.0 · Nov 27, 2026"
            )
            .padding(14)
        }
        .frame(width: 360, height: height)
        .superTheme(theme)
        .dynamicTypeSize(dynamicType)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 360, height: height)),
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
