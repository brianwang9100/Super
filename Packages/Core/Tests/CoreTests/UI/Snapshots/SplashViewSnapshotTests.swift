#if canImport(UIKit)
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import Core

/// Snapshots for `SplashView` across the three themes plus a Dynamic Type
/// XXL variant on Light. The view is constructed with
/// `skipEntranceAnimation: true` so the captured frame is the resting pose
/// (full opacity, pulse at peak) — animation timing isn't a thing we can
/// hold steady in a snapshot.
///
/// Note on the XXL variant: `SplashView` uses `Font.custom(name, size:)`
/// with fixed point sizes per SPEC, so `.dynamicTypeSize(.xxLarge)` does
/// NOT scale the wordmark or version line. The XXL test is therefore a
/// layout-stability regression check, not an accessibility-text-scaling
/// check — the splash deliberately ignores Dynamic Type per design.
@Suite("SplashView snapshots")
@MainActor
struct SplashViewSnapshotTests {
    init() {
        // SwiftUI snapshot tests run in a fresh xctest process that never
        // hits `SuperOSApp.init()`, so the bundled `.ttf`s are unregistered
        // and `Font.custom("EBGaramond-Italic", …)` silently falls
        // back to system sans-serif. The static-let inside is idempotent,
        // so calling per-test costs nothing after the first hit.
        Core.registerBundledFonts()
        // Hard-fail if registration didn't actually land — otherwise the
        // snapshots would silently bake the system-font fallback and lock
        // it in as the source of truth. `UIFont(name:size:)` returns nil
        // when the PostScript name is unresolved.
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
        verify(theme: .light, name: "splash_light")
    }

    @Test("dark")
    func dark() {
        verify(theme: .dark, name: "splash_dark")
    }

    @Test("sepia")
    func sepia() {
        verify(theme: .sepia, name: "splash_sepia")
    }

    @Test("dynamic type XXL light")
    func dynamicTypeXXLLight() {
        let function = #function
        let view = SplashView(name: "Super", version: "1.0", skipEntranceAnimation: true)
            .superTheme(.make(.light))
            .dynamicTypeSize(.xxLarge)
            .frame(width: 402, height: 874)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 874)),
            named: "splash_light_xxl",
            record: SnapshotEnvironment.isRecording ? .all : nil,
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

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 874)),
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
