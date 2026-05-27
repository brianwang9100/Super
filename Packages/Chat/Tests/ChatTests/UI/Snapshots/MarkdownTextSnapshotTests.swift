#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

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
/// Snapshot matrix per root AGENTS.md §Testing.3 — light, dark, sepia
/// at default Dynamic Type, plus one XXL variant on light to catch
/// scaled-font regressions in the link runs.
///
/// `.serialized` — baselines are PNG files; parallel execution would
/// race on the on-disk cache. Matches every other snapshot suite in
/// this folder.
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

    @Test("linkified verse references — light")
    func light() {
        verify(theme: .light, name: "markdown_verse_refs_light")
    }

    @Test("linkified verse references — dark")
    func dark() {
        verify(theme: .dark, name: "markdown_verse_refs_dark")
    }

    @Test("linkified verse references — sepia")
    func sepia() {
        verify(theme: .sepia, name: "markdown_verse_refs_sepia")
    }

    @Test("linkified verse references at Dynamic Type XXL — light")
    func dynamicTypeXXL() {
        verify(theme: .light, dynamicType: .xxLarge, name: "markdown_verse_refs_light_xxl")
    }

    private func verify(
        theme: SuperTheme.Identifier,
        dynamicType: DynamicTypeSize = .large,
        name: String,
        function: String = #function
    ) {
        let view = MarkdownText(Self.sample)
            .superTheme(.make(theme))
            .dynamicTypeSize(dynamicType)
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
