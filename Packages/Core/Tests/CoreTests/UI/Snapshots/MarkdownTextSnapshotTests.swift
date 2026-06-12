#if canImport(UIKit)
import SnapshotTesting
import SwiftUI
import Testing
@testable import Core

/// Visual baselines for ``MarkdownText`` rendering Bible verse
/// references the chat-side linkifier wraps into `super://bible/...`
/// markdown links. A unit test (`MarkdownTextTests`) pins that the
/// pre-MarkdownUI string contains the linkified form; these snapshots
/// pin the *rendered* appearance — anchor + continuation refs styled
/// as links — across the project's standard theme matrix.
///
/// The fixture text deliberately mixes:
///   - an anchor `Romans 8:28-30` plus a `;`-continuation `12:1-2`
///   - a fresh-book anchor `Psalm 23` after a paragraph break
///   - a deliberate non-ref `Section 1:2` that must stay plain text
///   - an inline-code `` `Genesis 1:1` `` that must stay verbatim
/// so the snapshot exercises the full inheritance and skip-region
/// behavior in one shot.
///
/// Two fixtures: a prose one (above) and a bulleted-list one that pins
/// inter-item spacing (now tracking the line spacing) and link styling
/// inside list items.
///
/// Snapshot matrix per root AGENTS.md §Testing.3 — vellumLight /
/// vellumDark at default Dynamic Type. The prose fixture adds one XXL
/// variant on light to catch scaled-font regressions in the link runs;
/// the list fixture adds a 1.2× font-slider variant on light, since
/// `MarkdownText` scales off the injected metrics
/// (`MarkdownBodyMetrics.fontScale`), not Dynamic Type — that's the
/// axis the inter-item spacing tracks.
///
/// Not `.serialized`: Core's snapshot suites don't serialize (root
/// AGENTS.md §Testing.7 — serialization is per-module all-or-none, and
/// order-independence comes from the font registration in `init`, not
/// from serialization). The suite was serialized in its original ChatTests
/// home, where the whole module serializes.
@Suite("MarkdownText snapshots")
@MainActor
struct MarkdownTextSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    private static let sample: String = """
    A few passages worth holding side-by-side:

    Romans 8:28-30 reads as a single thread; the same chapter circles back in 12:1-2.

    Psalm 23 grounds the metaphor; Section 1:2 of the appendix below is unrelated.

    Note that `Genesis 1:1` written inline should not tap through.
    """

    /// A bulleted-list fixture (verse refs *inside* the items) — pins the
    /// inter-item spacing, which now tracks the intra-paragraph line spacing
    /// (`MarkdownBodyMetrics.paragraphLineSpacingPoints`) instead of a fixed 2pt,
    /// so a list's item-to-item rhythm tracks the wrapped lines inside an
    /// item. Also exercises link styling within list items, which the prose
    /// fixture above doesn't reach.
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
        // The app font-scale slider (projected here as
        // `MarkdownBodyMetrics.fontScale`), not OS Dynamic Type, is what the
        // user reported the cramped bullets on — `MarkdownText`'s body size
        // reads the injected metrics, not Dynamic Type. This pins the
        // spacious end where the line-spacing/inter-item match is most
        // visible.
        verify(theme: .vellumLight, metrics: MarkdownBodyMetrics(fontScale: 1.2), text: Self.listSample, wrap: true, name: "markdown_list_refs_light_scale120")
    }

    /// - Parameter wrap: forces the markdown to wrap to the 402pt width
    ///   (`.fixedSize` vertical) instead of laying out single-line and
    ///   truncating. The list fixtures need it so a multi-line item is
    ///   visible alongside the inter-item gap — that's the whole point of the
    ///   spacing change. The prose fixtures keep the suite's original
    ///   single-line layout (their baselines are unchanged).
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

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .sizeThatFits),
            named: name,
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure { Issue.record("\(name): \(failure)") }
    }
}
#endif
