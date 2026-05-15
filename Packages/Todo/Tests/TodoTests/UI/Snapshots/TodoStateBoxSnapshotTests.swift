#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Todo

/// Snapshots for `TodoStateBox` — the three states (open / done /
/// cancelled) rendered side-by-side — across the three themes plus a
/// larger Dynamic Type size.
@Suite("TodoStateBox snapshots", .serialized)
@MainActor
struct TodoStateBoxSnapshotTests {
    @Test("light theme") func light() {
        verify(theme: .light, name: "state_box_light")
    }

    @Test("dark theme") func dark() {
        verify(theme: .dark, name: "state_box_dark")
    }

    @Test("sepia theme") func sepia() {
        verify(theme: .sepia, name: "state_box_sepia")
    }

    @Test("dynamic type XXL") func dynamicTypeXXL() {
        verify(theme: .light, dynamicType: .xxLarge, name: "state_box_light_xxl")
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

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 90)),
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
