#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Todo

/// Snapshots for `TodoSectionHeader` across the three themes plus a larger
/// Dynamic Type size.
@Suite("TodoSectionHeader snapshots", .serialized)
@MainActor
struct TodoSectionHeaderSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    @Test("light theme") func light() {
        verify(theme: .light, name: "section_header_light")
    }

    @Test("dark theme") func dark() {
        verify(theme: .dark, name: "section_header_dark")
    }

    @Test("sepia theme") func sepia() {
        verify(theme: .sepia, name: "section_header_sepia")
    }

    @Test("dynamic type XXL") func dynamicTypeXXL() {
        verify(theme: .light, dynamicType: .xxLarge, name: "section_header_light_xxl")
    }

    private func verify(
        theme: SuperTheme.Identifier,
        dynamicType: DynamicTypeSize = .large,
        name: String,
        function: String = #function
    ) {
        let resolved = SuperTheme.make(theme)
        let view = TodoSectionHeader(title: "Today", count: 3)
            .padding(.horizontal, 14)
            .frame(width: 402, height: 120, alignment: .topLeading)
            .background(resolved.background)
            .superTheme(resolved)
            .dynamicTypeSize(dynamicType)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 120)),
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
