#if canImport(UIKit)
import Core
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Todo

@Suite("TodoEmptyState snapshots", .serialized)
@MainActor
struct TodoEmptyStateSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("light theme") func light() {
        verify(theme: .vellumLight, name: "empty_light")
    }

    @Test("dark theme") func dark() {
        verify(theme: .vellumDark, name: "empty_dark")
    }

    @Test("dynamic type XXL") func dynamicTypeXXL() {
        verify(theme: .vellumLight, dynamicType: .xxLarge, name: "empty_light_xxl")
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

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 300)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
