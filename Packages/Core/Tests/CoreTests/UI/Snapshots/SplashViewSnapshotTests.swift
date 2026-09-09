#if canImport(UIKit)
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
import UIKit
@testable import Core

@Suite("SplashView snapshots", .serialized)
@MainActor
struct SplashViewSnapshotTests {
    init() {
        // Test hosts skip app initialization, so register fonts before rendering.
        Core.registerBundledFonts()
        precondition(
            UIFont(name: "EBGaramond-Italic", size: 38) != nil,
            "EBGaramond-Italic failed to register — snapshots would capture fallback faces"
        )
        precondition(
            UIFont(name: "JetBrainsMono-Regular", size: 10.5) != nil,
            "JetBrains Mono Regular failed to register — snapshots would capture fallback faces"
        )
    }

    @Test("light")
    func light() {
        verify(theme: .vellumLight, name: "splash_light")
    }

    @Test("dark")
    func dark() {
        verify(theme: .vellumDark, name: "splash_dark")
    }

    @Test("dynamic type XXL light")
    func dynamicTypeXXLLight() {
        let function = #function
        let view = SplashView(name: "Super", version: "1.0", skipEntranceAnimation: true)
            .superTheme(.make(.vellumLight))
            .dynamicTypeSize(.xxLarge)
            .frame(width: 402, height: 874)

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 874)),
            named: "splash_light_xxl",
            testName: function
        )
        if let failure {
            Issue.record("splash_light_xxl: \(failure)")
        }
    }

    private func verify(
        theme: SuperTheme.Identifier,
        name: String,
        function: String = #function
    ) {
        let view = SplashView(name: "Super", version: "1.0", skipEntranceAnimation: true)
            .superTheme(.make(theme))
            .frame(width: 402, height: 874)

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 874)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
