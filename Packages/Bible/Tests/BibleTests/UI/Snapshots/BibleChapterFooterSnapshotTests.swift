#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `BibleChapterFooter` — the prev / next cards that close the
/// reading column. Captured standalone because in a full `BibleScreen` the
/// footer sits below a long chapter, off the captured frame.
///
/// The both-cards state covers the three themes; the single-card states
/// cover the canon's two ends, where one card drops out.
@Suite("BibleChapterFooter snapshots")
@MainActor
struct BibleChapterFooterSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("both cards render in the light theme")
    func bothLight() {
        verify(theme: .light, previous: "1 Peter 1", next: "1 Peter 3", name: "both_light")
    }

    @Test("both cards render in the dark theme")
    func bothDark() {
        verify(theme: .dark, previous: "1 Peter 1", next: "1 Peter 3", name: "both_dark")
    }

    @Test("both cards render in the sepia theme")
    func bothSepia() {
        verify(theme: .sepia, previous: "1 Peter 1", next: "1 Peter 3", name: "both_sepia")
    }

    @Test("only the previous card renders at the end of the canon")
    func previousOnly() {
        verify(theme: .light, previous: "Revelation 21", next: nil, name: "previous_only_light")
    }

    @Test("only the next card renders at the start of the canon")
    func nextOnly() {
        verify(theme: .light, previous: nil, next: "Genesis 2", name: "next_only_light")
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

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 140)),
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
