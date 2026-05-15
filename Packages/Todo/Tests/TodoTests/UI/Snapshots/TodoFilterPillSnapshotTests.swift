#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Todo

/// Snapshots for `TodoFilterPill` across the three themes plus a larger
/// Dynamic Type size.
@Suite("TodoFilterPill snapshots", .serialized)
@MainActor
struct TodoFilterPillSnapshotTests {
    @Test("light theme") func light() {
        verify(theme: .light, name: "filter_pill_light")
    }

    @Test("dark theme") func dark() {
        verify(theme: .dark, name: "filter_pill_dark")
    }

    @Test("sepia theme") func sepia() {
        verify(theme: .sepia, name: "filter_pill_sepia")
    }

    @Test("dynamic type XXL") func dynamicTypeXXL() {
        verify(theme: .light, dynamicType: .xxLarge, name: "filter_pill_light_xxl")
    }

    private func verify(
        theme: SuperTheme.Identifier,
        dynamicType: DynamicTypeSize = .large,
        name: String,
        function: String = #function
    ) {
        let resolved = SuperTheme.make(theme)
        let view = TodoFilterPill(summary: "Open · 2 tags · by priority") {}
            .padding(18)
            .frame(width: 402, height: 130, alignment: .topLeading)
            .background(resolved.background)
            .superTheme(resolved)
            .dynamicTypeSize(dynamicType)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 130)),
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
