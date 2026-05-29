#if canImport(UIKit)
import Core
import Testing
import UIKit

/// Registers the bundled brand fonts once per test process so snapshot
/// suites render the real Instrument Serif face instead of the system
/// serif fallback. Mirrors the app targets' `Core.registerBundledFonts()`
/// call, which never runs in the unit-test host.
@MainActor
enum SnapshotFontRegistration {
    private static var verified = false

    static func ensureRegistered() {
        if verified { return }
        verified = true
        Core.registerBundledFonts()
        if UIFont(name: "InstrumentSerif-Italic", size: 26) == nil {
            Issue.record("Instrument Serif Italic failed to register — snapshots would bake the system-serif fallback")
        }
    }
}
#endif
