#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `NoteListSheet` — the bottom sheet listing a range's
/// notes. Variants cover the empty-state hero across all themes, a
/// single-note list, a many-note scrolling list across all themes, and a
/// Dynamic Type XXL pass that exercises the nav bar + card reflow.
@Suite("NoteListSheet snapshots")
@MainActor
struct NoteListSheetSnapshotTests {
    /// Register Core's bundled brand fonts so the migrated JetBrains Mono /
    /// EB Garamond chrome faces resolve instead of baking the system
    /// fallback, and so this suite stays order-independent (registration is
    /// process-global; see `SnapshotFontRegistration`).
    init() { SnapshotFontRegistration.ensureRegistered() }

    private static let citation = "John 3:16–18"

    private static let many: [NoteListSheet.Item] = [
        NoteListSheet.Item(
            id: "1", dateWritten: "May 28, 2026",
            text: "The Greek here is monogenēs — \"one of a kind,\" not \"only-begotten\" in any biological sense. And v17 deliberately balances v16: the Son is sent not to condemn the world but so that it might be saved through him.",
            author: "Claude"
        ),
        NoteListSheet.Item(
            id: "2", dateWritten: "May 24, 2026",
            text: "This is the hinge of the whole gospel. \"God so loved the world\" — the love comes first, before anything is asked of us. Come back here when belief starts to feel like effort."
        ),
        NoteListSheet.Item(
            id: "3", dateWritten: "May 20, 2026",
            text: "Memorise v17. I always quote the first half and forget that he did not come to condemn."
        ),
        NoteListSheet.Item(
            id: "4", dateWritten: "May 18, 2026",
            text: "Cross-reference with 1 John 4:9 — the same \"sent\" language about love being given rather than summoned."
        ),
        NoteListSheet.Item(
            id: "5", dateWritten: "Dec 30, 2025",
            text: "Read this one at the service. It held."
        ),
    ]

    @Test("empty list renders the hero in the light theme")
    func emptyLight() {
        verify(theme: .vellumLight, items: [], name: "empty_light")
    }

    @Test("empty list renders the hero in the dark theme")
    func emptyDark() {
        verify(theme: .vellumDark, items: [], name: "empty_dark")
    }

    @Test("empty list renders the hero in the sepia theme")
    func emptySepia() {
        verify(theme: .sepiaLight, items: [], name: "empty_sepia")
    }

    @Test("a single note renders the singular subtitle")
    func oneLight() {
        verify(theme: .vellumLight, items: [Self.many[1]], name: "one_light")
    }

    @Test("a single note renders the singular subtitle in the dark theme")
    func oneDark() {
        verify(theme: .vellumDark, items: [Self.many[1]], name: "one_dark")
    }

    @Test("a single note renders the singular subtitle in the sepia theme")
    func oneSepia() {
        verify(theme: .sepiaLight, items: [Self.many[1]], name: "one_sepia")
    }

    @Test("many notes scroll in the light theme")
    func manyLight() {
        verify(theme: .vellumLight, items: Self.many, name: "many_light")
    }

    @Test("many notes scroll in the dark theme")
    func manyDark() {
        verify(theme: .vellumDark, items: Self.many, name: "many_dark")
    }

    @Test("many notes scroll in the sepia theme")
    func manySepia() {
        verify(theme: .sepiaLight, items: Self.many, name: "many_sepia")
    }

    @Test("many notes hold shape at Dynamic Type XXL")
    func manyLightXXL() {
        verify(theme: .vellumLight, items: Self.many, dynamicType: .xxLarge, name: "many_light_xxl")
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        items: [NoteListSheet.Item],
        dynamicType: DynamicTypeSize = .large,
        height: CGFloat = 680,
        name: String,
        function: String = #function
    ) {
        let theme = SuperTheme.make(themeID)
        let view = ZStack {
            theme.background
            NoteListSheet(
                citation: Self.citation,
                items: items,
                onClose: {},
                onCompose: {},
                onSelect: { _ in },
                onDelete: { _ in },
                bottomInset: 0
            )
        }
        .frame(width: 393, height: height)
        .superTheme(theme)
        .dynamicTypeSize(dynamicType)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: height)),
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
