#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `BibleNavBar` — the reading surface's top bar in its default
/// state across the three themes, with each chapter arrow disabled at the
/// canon's two ends, and in selection mode where the centre group collapses
/// to a citation pill.
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

    @Test("selection mode collapses the centre group to a citation pill")
    func selectionLight() {
        verify(theme: .light, canStepBackward: true, canStepForward: true,
               name: "selection_light", selectionCitation: "1 Peter 2:4-6, 9")
    }

    @Test("selection mode renders in the dark theme")
    func selectionDark() {
        verify(theme: .dark, canStepBackward: true, canStepForward: true,
               name: "selection_dark", selectionCitation: "1 Peter 2:4-6, 9")
    }

    @Test("selection mode renders in the sepia theme")
    func selectionSepia() {
        verify(theme: .sepia, canStepBackward: true, canStepForward: true,
               name: "selection_sepia", selectionCitation: "1 Peter 2:4-6, 9")
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        canStepBackward: Bool,
        canStepForward: Bool,
        name: String,
        selectionCitation: String? = nil,
        function: String = #function
    ) {
        let theme = SuperTheme.make(themeID)
        let view = ZStack(alignment: .top) {
            theme.background
            BibleNavBar(
                bookName: "1 Peter",
                chapterNumber: 2,
                translation: .web,
                selectionCitation: selectionCitation,
                canStepBackward: canStepBackward,
                canStepForward: canStepForward,
                onPrevious: {},
                onNext: {},
                onPill: {},
                onTranslation: {},
                onClearSelection: {},
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
