#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `BibleActionSheet` — the selection action sheet across the
/// three themes and for both a single-verse and a multi-range citation. The
/// sheet uses fixed type sizes (OS Dynamic Type support is deferred
/// app-wide), so no Dynamic Type variant is recorded.
@Suite("BibleActionSheet snapshots")
@MainActor
struct BibleActionSheetSnapshotTests {
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

    private func verify(
        theme themeID: SuperTheme.Identifier,
        citation: String,
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
                onClose: {}
            )
        }
        .frame(width: 402, height: 220)
        .superTheme(theme)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 220)),
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
