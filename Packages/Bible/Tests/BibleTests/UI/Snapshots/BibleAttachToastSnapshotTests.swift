#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `BibleAttachToast` — the chat-attach "coming soon" toast.
///
/// The toast is a fixed dark card regardless of theme; the baselines confirm
/// it reads against the light, dark, and sepia page backgrounds. The card
/// uses fixed type sizes, so no Dynamic Type variant is recorded.
@Suite("BibleAttachToast snapshots")
@MainActor
struct BibleAttachToastSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("the toast renders over a light page")
    func light() {
        verify(theme: .vellumLight, name: "light")
    }

    @Test("the toast renders over a dark page")
    func dark() {
        verify(theme: .vellumDark, name: "dark")
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let theme = SuperTheme.make(themeID)
        let view = ZStack(alignment: .bottom) {
            theme.background
            BibleAttachToast(
                message: "Chat integration ships in a later update.",
                onDismiss: {}
            )
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
