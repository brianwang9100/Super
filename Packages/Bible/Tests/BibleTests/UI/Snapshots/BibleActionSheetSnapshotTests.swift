#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `BibleActionSheet` — the selection action sheet across the
/// three themes and for both a single-verse and a multi-range citation. The
/// sheet stacks the AI action row over the plain-text (Copy/Share) row, split
/// by a hairline divider. The sheet's own type sizes are fixed, but a Dynamic
/// Type XXL variant is recorded per root `AGENTS.md` §Testing — it guards
/// against a future font change reflowing the swatch / action rows.
@Suite("BibleActionSheet snapshots")
@MainActor
struct BibleActionSheetSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("the action sheet renders in the light theme")
    func light() {
        verify(theme: .light, citation: "1 Peter 2:9", name: "light")
    }

    @Test("the action sheet renders in the dark theme")
    func dark() {
        verify(theme: .dark, citation: "1 Peter 2:9", name: "dark")
    }

    @Test("the action sheet renders in the sepia theme")
    func sepia() {
        verify(theme: .sepia, citation: "1 Peter 2:9", name: "sepia")
    }

    @Test("the action sheet renders a multi-range citation")
    func multiRange() {
        verify(theme: .light, citation: "1 Peter 2:4-6, 9", name: "multi_range_light")
    }

    @Test("the action sheet renders at Dynamic Type XXL")
    func lightXXL() {
        verify(theme: .light, citation: "1 Peter 2:9", dynamicType: .xxLarge,
               name: "light_xxl")
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        citation: String,
        dynamicType: DynamicTypeSize = .large,
        name: String,
        function: String = #function
    ) {
        let theme = SuperTheme.make(themeID)
        let view = ZStack(alignment: .bottom) {
            theme.background
            BibleActionSheet(
                citation: citation,
                shareText: "…",
                onHighlight: { _ in },
                onClearHighlight: {},
                onCopy: {},
                onAddToChat: {},
                onNewChat: {},
                onAnnotate: {},
                onAddNote: {},
                onClose: {}
            )
        }
        .frame(width: 402, height: 330)
        .superTheme(theme)
        .dynamicTypeSize(dynamicType)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 330)),
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
