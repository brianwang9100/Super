#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `BibleNavBar` — the reading surface's top bar in its default
/// state across the three themes, and with each chapter arrow disabled at
/// the canon's two ends.
@Suite("BibleNavBar snapshots")
@MainActor
struct BibleNavBarSnapshotTests {
    @Test("the nav bar renders in the light theme")
    func defaultLight() {
        verify(theme: .light, canStepBackward: true, canStepForward: true, name: "default_light")
    }

    @Test("the nav bar renders in the dark theme")
    func defaultDark() {
        verify(theme: .dark, canStepBackward: true, canStepForward: true, name: "default_dark")
    }

    @Test("the nav bar renders in the sepia theme")
    func defaultSepia() {
        verify(theme: .sepia, canStepBackward: true, canStepForward: true, name: "default_sepia")
    }

    @Test("the previous arrow is disabled at the start of the canon")
    func previousDisabled() {
        verify(theme: .light, canStepBackward: false, canStepForward: true,
               name: "previous_disabled_light")
    }

    @Test("the next arrow is disabled at the end of the canon")
    func nextDisabled() {
        verify(theme: .light, canStepBackward: true, canStepForward: false,
               name: "next_disabled_light")
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        canStepBackward: Bool,
        canStepForward: Bool,
        name: String,
        function: String = #function
    ) {
        let theme = SuperTheme.make(themeID)
        let view = ZStack(alignment: .top) {
            theme.background
            BibleNavBar(
                bookName: "1 Peter",
                chapterNumber: 2,
                translation: .web,
                canStepBackward: canStepBackward,
                canStepForward: canStepForward,
                onPrevious: {},
                onNext: {},
                onPill: {},
                onTranslation: {},
                onPlus: {}
            )
        }
        .frame(width: 402, height: 96)
        .superTheme(theme)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 96)),
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
