#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `SparkButton` — the chapter-nav "Annotate selection"
/// trigger in both states across the three themes. The dim/active gap
/// is the load-bearing visual: `dim` should read as inert, `active` as
/// the strongest accent target in the nav strip.
@Suite("SparkButton snapshots")
@MainActor
struct SparkButtonSnapshotTests {
    @Test("dim button renders in the light theme")
    func dimLight() {
        verify(theme: .light, state: .dim, name: "dim_light")
    }

    @Test("dim button renders in the dark theme")
    func dimDark() {
        verify(theme: .dark, state: .dim, name: "dim_dark")
    }

    @Test("dim button renders in the sepia theme")
    func dimSepia() {
        verify(theme: .sepia, state: .dim, name: "dim_sepia")
    }

    @Test("active button renders in the light theme")
    func activeLight() {
        verify(theme: .light, state: .active, name: "active_light")
    }

    @Test("active button renders in the dark theme")
    func activeDark() {
        verify(theme: .dark, state: .active, name: "active_dark")
    }

    @Test("active button renders in the sepia theme")
    func activeSepia() {
        verify(theme: .sepia, state: .active, name: "active_sepia")
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        state: SparkButton.State,
        name: String,
        function: String = #function
    ) {
        let theme = SuperTheme.make(themeID)
        let view = ZStack {
            theme.background
            SparkButton(state: state, action: {})
        }
        .frame(width: 96, height: 96)
        .superTheme(theme)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 96, height: 96)),
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
