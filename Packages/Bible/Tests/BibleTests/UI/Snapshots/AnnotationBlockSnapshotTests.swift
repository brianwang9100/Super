#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `AnnotationBlock` — one card row in `AnnotationSheet`.
/// Variants cover the three body shapes (text, parsed reference,
/// unparsed reference fallback), the three themes for text, and a
/// long-body × Dynamic Type XXL combo that guards against future font
/// changes silently truncating cards.
@Suite("AnnotationBlock snapshots")
@MainActor
struct AnnotationBlockSnapshotTests {
    private static let shortBody = "Paul, writing from prison in Rome around 60 AD. Romans is the longest of his letters and the most systematic."

    private static let longBody = """
    There is a long tradition of reading this verse as a comfort to the suffering, but Calvin pushes back: it is not a promise that everything will feel good, only that nothing — pain, loss, even death — falls outside of what God can weave toward our good. "Good" here means conformity to Christ (v29), not pleasant circumstances. The cross is the pattern.
    """

    @Test("text card renders in the light theme")
    func textLight() {
        verify(
            theme: .light,
            title: "Author",
            content: .text(Self.shortBody),
            name: "text_light"
        )
    }

    @Test("text card renders in the dark theme")
    func textDark() {
        verify(
            theme: .dark,
            title: "Author",
            content: .text(Self.shortBody),
            name: "text_dark"
        )
    }

    @Test("text card renders in the sepia theme")
    func textSepia() {
        verify(
            theme: .sepia,
            title: "Author",
            content: .text(Self.shortBody),
            name: "text_sepia"
        )
    }

    @Test("reference card with parsed target shows pill button")
    func referenceParsedLight() {
        let target = BibleCitationParser.ParsedCitation(
            position: BiblePosition(bookId: "JHN", chapterNumber: 1),
            verseStart: 14, verseEnd: 14
        )
        verify(
            theme: .light,
            category: .reference,
            title: "Cross-reference",
            content: .reference(label: "John 1:14", target: target),
            name: "reference_parsed_light"
        )
    }

    @Test("reference card with parsed target renders the pill in dark")
    func referenceParsedDark() {
        let target = BibleCitationParser.ParsedCitation(
            position: BiblePosition(bookId: "JHN", chapterNumber: 1),
            verseStart: 14, verseEnd: 14
        )
        verify(
            theme: .dark,
            category: .reference,
            title: "Cross-reference",
            content: .reference(label: "John 1:14", target: target),
            name: "reference_parsed_dark"
        )
    }

    @Test("reference card with parsed target renders the pill in sepia")
    func referenceParsedSepia() {
        let target = BibleCitationParser.ParsedCitation(
            position: BiblePosition(bookId: "JHN", chapterNumber: 1),
            verseStart: 14, verseEnd: 14
        )
        verify(
            theme: .sepia,
            category: .reference,
            title: "Cross-reference",
            content: .reference(label: "John 1:14", target: target),
            name: "reference_parsed_sepia"
        )
    }

    @Test("reference card with parse failure falls back to plain text")
    func referenceUnparsedLight() {
        verify(
            theme: .light,
            category: .reference,
            title: "Parse failed",
            content: .reference(label: "John 14, verse twelve", target: nil),
            name: "reference_unparsed_light"
        )
    }

    @Test("reference parse-failure fallback renders in dark")
    func referenceUnparsedDark() {
        verify(
            theme: .dark,
            category: .reference,
            title: "Parse failed",
            content: .reference(label: "John 14, verse twelve", target: nil),
            name: "reference_unparsed_dark"
        )
    }

    @Test("reference parse-failure fallback renders in sepia")
    func referenceUnparsedSepia() {
        verify(
            theme: .sepia,
            category: .reference,
            title: "Parse failed",
            content: .reference(label: "John 14, verse twelve", target: nil),
            name: "reference_unparsed_sepia"
        )
    }

    @Test("long body wraps without truncation")
    func longBodyLight() {
        verify(
            theme: .light,
            category: .clarification,
            title: "Reformed reading",
            content: .text(Self.longBody),
            height: 280,
            name: "long_body_light"
        )
    }

    @Test("long body wraps in the dark theme")
    func longBodyDark() {
        verify(
            theme: .dark,
            category: .clarification,
            title: "Reformed reading",
            content: .text(Self.longBody),
            height: 280,
            name: "long_body_dark"
        )
    }

    @Test("long body wraps in the sepia theme")
    func longBodySepia() {
        verify(
            theme: .sepia,
            category: .clarification,
            title: "Reformed reading",
            content: .text(Self.longBody),
            height: 280,
            name: "long_body_sepia"
        )
    }

    @Test("long body renders at Dynamic Type XXL")
    func longBodyLightXXL() {
        verify(
            theme: .light,
            category: .clarification,
            title: "Reformed reading",
            content: .text(Self.longBody),
            height: 400,
            dynamicType: .xxLarge,
            name: "long_body_light_xxl"
        )
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        category: BibleAnnotationCategory = .author,
        title: String,
        content: AnnotationBlock.Content,
        height: CGFloat = 180,
        dynamicType: DynamicTypeSize = .large,
        name: String,
        function: String = #function
    ) {
        let theme = SuperTheme.make(themeID)
        let view = ZStack {
            theme.background
            AnnotationBlock(
                category: category,
                title: title,
                content: content,
                provenance: "Generated by AFM 3.0 · Nov 27, 2026",
                onAddToChat: {},
                onDelete: {},
                onOpenReference: { _ in }
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
