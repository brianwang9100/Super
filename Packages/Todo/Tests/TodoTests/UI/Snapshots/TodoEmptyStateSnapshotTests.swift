#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Todo

/// Snapshots for `TodoEmptyState` across the three themes plus a larger
/// Dynamic Type size.
// `.serialized` — snapshot baselines are read/written per-test against the
// same on-disk `__Snapshots__/` directory; parallel execution races on the
// PNG files. Matches every snapshot suite in the codebase.
@Suite("TodoEmptyState snapshots", .serialized)
@MainActor
struct TodoEmptyStateSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("light theme") func light() {
        verify(theme: .light, name: "empty_light")
    }

    @Test("dark theme") func dark() {
        verify(theme: .dark, name: "empty_dark")
    }

    @Test("sepia theme") func sepia() {
        verify(theme: .sepia, name: "empty_sepia")
    }

    @Test("dynamic type XXL") func dynamicTypeXXL() {
        verify(theme: .light, dynamicType: .xxLarge, name: "empty_light_xxl")
    }

    private func verify(
        theme: SuperTheme.Identifier,
        dynamicType: DynamicTypeSize = .large,
        name: String,
        function: String = #function
    ) {
        let resolved = SuperTheme.make(theme)
        let view = TodoEmptyState()
            .frame(width: 402, height: 300, alignment: .center)
            .background(resolved.background)
            .superTheme(resolved)
            .dynamicTypeSize(dynamicType)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 300)),
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
