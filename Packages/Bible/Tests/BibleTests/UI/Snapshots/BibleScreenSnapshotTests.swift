#if canImport(UIKit)
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// M0 placeholder-screen snapshots. Light + dark cover what `BibleScreen`'s
/// system colours (`Color.primary`, `Color(.systemBackground)`) actually
/// distinguish, plus a Dynamic Type XXL variant per root `AGENTS.md`
/// §Testing rule 3 to catch regressions in the `.callout`-sized "Coming
/// soon." caption (the 36-pt `Bible` title is fixed-point and won't scale).
/// Sepia lands in M1 once Bible can consume `SuperTheme`.
@Suite("BibleScreen snapshots")
@MainActor
struct BibleScreenSnapshotTests {
    @Test("M0 placeholder renders in system light")
    func placeholderLight() {
        verify(colorScheme: .light, name: "placeholder_light")
    }

    @Test("M0 placeholder renders in system dark")
    func placeholderDark() {
        verify(colorScheme: .dark, name: "placeholder_dark")
    }

    @Test("M0 placeholder renders in system light at Dynamic Type XXL")
    func placeholderLightXXL() {
        verify(
            colorScheme: .light,
            dynamicTypeSize: .xxLarge,
            name: "placeholder_light_xxl"
        )
    }

    private func verify(
        colorScheme: ColorScheme,
        dynamicTypeSize: DynamicTypeSize = .large,
        name: String,
        function: String = #function
    ) {
        // `.environment(\.colorScheme, ...)` flips the environment value
        // SwiftUI views actually read; `.preferredColorScheme(...)` is a
        // window-scene-level hint that doesn't propagate into the
        // `UIHostingController` snapshot-testing wraps the view in.
        let view = BibleScreen()
            .environment(\.colorScheme, colorScheme)
            .dynamicTypeSize(dynamicTypeSize)
            .frame(width: 402, height: 600)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 600)),
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
