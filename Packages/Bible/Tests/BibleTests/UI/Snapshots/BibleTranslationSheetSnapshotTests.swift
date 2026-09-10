#if canImport(UIKit)
import Core
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Bible

@Suite("BibleTranslationSheet snapshots", .serialized)
@MainActor
struct BibleTranslationSheetSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("the picker renders in the light theme")
    func light() {
        verify(theme: .vellumLight, name: "light")
    }

    @Test("the picker renders in the dark theme")
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
            BibleTranslationSheet(
                current: .kjv,
                bottomInset: 0,
                onSelect: { _ in },
                onClose: {}
            )
        }
        .frame(width: 402, height: 420)
        .superTheme(theme)

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 420)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
