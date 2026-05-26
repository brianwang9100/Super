#if canImport(UIKit)
import Core
import Testing
import UIKit

/// One-time, process-global registration of `Core`'s bundled `.ttf` fonts
/// for snapshot tests. The xctest host never runs the app's `init()`, so
/// any `Font.custom(...)` against an unregistered face silently bakes the
/// system fallback as the baseline. Call `ensureRegistered()` from every
/// snapshot suite that renders a bundled face.
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
        if UIFont(name: "JetBrainsMono-Regular", size: 10.5) == nil {
            Issue.record("JetBrains Mono Regular failed to register — snapshots would bake the system-mono fallback")
        }
    }
}
#endif
