#if canImport(UIKit)
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Core

@Suite("MarkdownText snapshots", .serialized)
@MainActor
struct MarkdownTextSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    private static let sample: String = """
    A few passages worth holding side-by-side:

    Romans 8:28-30 reads as a single thread; the same chapter circles back in 12:1-2.

    Psalm 23 grounds the metaphor; Section 1:2 of the appendix below is unrelated.

    Note that `Genesis 1:1` written inline should not tap through.
    """

    // List items cover inter-item spacing and inline links missing from the prose fixture.
    private static let listSample: String = """
    Three anchors worth holding side-by-side:

    - **Comfort:** Romans 8:28-30 reads as a single thread; the same chapter circles back in 8:31-39.
    - **Hope:** Psalm 23 grounds the metaphor; John 3:16-17 is its New Testament rhyme.
    - **Love:** 1 Corinthians 13:4-7 is the canonical definition; compare 1 John 4:7-8.

    Note that `Genesis 1:1` written inline should not tap through. Section 1:2 of the appendix below is also unrelated.
    """

    @Test("linkified verse references — light")
    func light() {
        verify(theme: .vellumLight, name: "markdown_verse_refs_light")
    }

    @Test("linkified verse references — dark")
    func dark() {
        verify(theme: .vellumDark, name: "markdown_verse_refs_dark")
    }

    @Test("linkified verse references at Dynamic Type XXL — light")
    func dynamicTypeXXL() {
        verify(theme: .vellumLight, dynamicType: .xxLarge, name: "markdown_verse_refs_light_xxl")
    }

    @Test("bulleted list with refs — light")
    func listLight() {
        verify(theme: .vellumLight, text: Self.listSample, wrap: true, name: "markdown_list_refs_light")
    }

    @Test("bulleted list with refs — dark")
    func listDark() {
        verify(theme: .vellumDark, text: Self.listSample, wrap: true, name: "markdown_list_refs_dark")
    }

    @Test("bulleted list with refs at the 1.2× font slider — light")
    func listSpacious() {
        // Reproduce the large app-slider setting where fixed bullet gaps looked cramped.
        verify(theme: .vellumLight, metrics: MarkdownBodyMetrics(fontScale: 1.2), text: Self.listSample, wrap: true, name: "markdown_list_refs_light_scale120")
    }

    /// wrap forces multiline layout at the captured width so item and wrapped-line gaps are both visible.
    private func verify(
        theme: SuperTheme.Identifier,
        dynamicType: DynamicTypeSize = .large,
        metrics: MarkdownBodyMetrics = .default,
        text: String = Self.sample,
        wrap: Bool = false,
        name: String,
        function: String = #function
    ) {
        let markdown = MarkdownText(text)
            .superTheme(.make(theme))
            .markdownBodyMetrics(metrics)
            .dynamicTypeSize(dynamicType)
        let view = Group {
            if wrap {
                markdown.fixedSize(horizontal: false, vertical: true)
            } else {
                markdown
            }
        }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(width: 402)
            .background(SuperTheme.make(theme).background)

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .sizeThatFits),
            named: name,
            testName: function
        )
        if let failure { Issue.record("\(name): \(failure)") }
    }
}
#endif
