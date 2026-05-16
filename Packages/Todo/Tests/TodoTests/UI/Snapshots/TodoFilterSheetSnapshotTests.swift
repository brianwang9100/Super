#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Todo

/// Snapshots for `TodoFilterSheet`. Each theme renders the sheet with a
/// non-default filter (a sort, a state scope, and one selected tag) plus a
/// label set, so the selected-pill and selected-chip styling is exercised.
@Suite("TodoFilterSheet snapshots", .serialized)
@MainActor
struct TodoFilterSheetSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("light theme") func light() {
        verify(theme: .light, name: "filter_sheet_light")
    }

    @Test("dark theme") func dark() {
        verify(theme: .dark, name: "filter_sheet_dark")
    }

    @Test("sepia theme") func sepia() {
        verify(theme: .sepia, name: "filter_sheet_sepia")
    }

    // The sheet scales its type through the app-wide `superFontScale`
    // slider rather than `@ScaledMetric`, so the larger-size variant drives
    // that path instead of Dynamic Type.
    @Test("large font scale") func largeFontScale() {
        verify(theme: .light, fontScale: 1.5, name: "filter_sheet_light_large")
    }

    private func label(_ id: String, _ name: String, hue: Double) -> LabelRecord {
        LabelRecord(id: id, name: name, hue: hue, createdAt: now, updatedAt: now)
    }

    private func verify(
        theme: SuperTheme.Identifier,
        fontScale: CGFloat = 1,
        name: String,
        function: String = #function
    ) {
        let resolved = SuperTheme.make(theme)
        let labels = [
            label("work", "Work", hue: 200),
            label("home", "Home", hue: 150),
            label("travel", "Travel", hue: 220),
        ]
        let filter = TodoFilter(sort: .dueDate, state: .all, labelIds: ["work"])
        let view = TodoFilterSheet(
            filter: .constant(filter),
            labels: labels,
            onClose: {}
        )
        .frame(width: 402, height: 540, alignment: .top)
        .background(resolved.background)
        .superTheme(resolved)
        .superFontScale(fontScale)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 540)),
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
