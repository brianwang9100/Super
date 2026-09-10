#if canImport(UIKit)
import Core
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Bible

/// Captured separately because full-screen snapshots leave this footer below the frame.
@Suite("BibleChapterFooter snapshots", .serialized)
@MainActor
struct BibleChapterFooterSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("both cards render in the light theme")
    func bothLight() {
        verify(theme: .vellumLight, previous: "1 Peter 1", next: "1 Peter 3", name: "both_light")
    }

    @Test("both cards render in the dark theme")
    func bothDark() {
        verify(theme: .vellumDark, previous: "1 Peter 1", next: "1 Peter 3", name: "both_dark")
    }

    @Test("only the previous card renders at the end of the canon")
    func previousOnly() {
        verify(theme: .vellumLight, previous: "Revelation 21", next: nil, name: "previous_only_light")
    }

    @Test("only the next card renders at the start of the canon")
    func nextOnly() {
        verify(theme: .vellumLight, previous: nil, next: "Genesis 2", name: "next_only_light")
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        previous: String?,
        next: String?,
        name: String,
        function: String = #function
    ) {
        let theme = SuperTheme.make(themeID)
        let view = ZStack {
            theme.background
            BibleChapterFooter(
                previousLabel: previous,
                nextLabel: next,
                onPrevious: {},
                onNext: {}
            )
            .padding(.horizontal, 26)
        }
        .frame(width: 402, height: 140)
        .superTheme(theme)

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 140)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
