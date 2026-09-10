#if canImport(UIKit)
import Core
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Todo

@Suite("TodoFilterSheet snapshots", .serialized)
@MainActor
struct TodoFilterSheetSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("light theme") func light() {
        verify(theme: .vellumLight, name: "filter_sheet_light")
    }

    @Test("dark theme") func dark() {
        verify(theme: .vellumDark, name: "filter_sheet_dark")
    }

    // The sheet scales its type through the app-wide `superFontScale`
    // slider rather than `@ScaledMetric`, so the larger-size variant drives
    // that path instead of Dynamic Type.
    @Test("large font scale") func largeFontScale() {
        verify(theme: .vellumLight, fontScale: 1.5, name: "filter_sheet_light_large")
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
            labels: labels
        )
        .frame(width: 402, height: 540, alignment: .top)
        .background(resolved.background)
        .superTheme(resolved)
        .superFontScale(fontScale)

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 540)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
