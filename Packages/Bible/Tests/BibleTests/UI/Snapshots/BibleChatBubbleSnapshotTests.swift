#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `BibleChatBubble` — the floating "Ask about this chapter…"
/// pill across the three themes. The pill uses fixed type sizes, so no
/// Dynamic Type variant is recorded.
@Suite("BibleChatBubble snapshots")
@MainActor
struct BibleChatBubbleSnapshotTests {
    @Test("the chat bubble renders in the light theme")
    func light() {
        verify(theme: .light, name: "light")
    }

    @Test("the chat bubble renders in the dark theme")
    func dark() {
        verify(theme: .dark, name: "dark")
    }

    @Test("the chat bubble renders in the sepia theme")
    func sepia() {
        verify(theme: .sepia, name: "sepia")
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let theme = SuperTheme.make(themeID)
        let view = ZStack(alignment: .bottom) {
            theme.background
            BibleChatBubble(onTap: {})
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
        }
        .frame(width: 402, height: 110)
        .superTheme(theme)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 110)),
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
