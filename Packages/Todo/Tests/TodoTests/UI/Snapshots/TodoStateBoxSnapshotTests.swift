#if canImport(UIKit)
import Core
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Todo

@Suite("TodoStateBox snapshots", .serialized)
@MainActor
struct TodoStateBoxSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("light theme") func light() {
        verify(theme: .vellumLight, name: "state_box_light")
    }

    @Test("dark theme") func dark() {
        verify(theme: .vellumDark, name: "state_box_dark")
    }

    @Test("dynamic type XXL") func dynamicTypeXXL() {
        verify(theme: .vellumLight, dynamicType: .xxLarge, name: "state_box_light_xxl")
    }

    private func verify(
        theme: SuperTheme.Identifier,
        dynamicType: DynamicTypeSize = .large,
        name: String,
        function: String = #function
    ) {
        let resolved = SuperTheme.make(theme)
        let view = HStack(spacing: 20) {
            TodoStateBox(state: .open) {}
            TodoStateBox(state: .done) {}
            TodoStateBox(state: .cancelled) {}
        }
        .padding(20)
        .frame(width: 402, height: 90, alignment: .center)
        .background(resolved.background)
        .superTheme(resolved)
        .dynamicTypeSize(dynamicType)

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 90)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
