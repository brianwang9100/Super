#if canImport(UIKit)
import Core
import UIKit

/// One-time, process-global registration of `Core`'s bundled `.ttf` fonts
/// for snapshot tests. The xctest host never runs the app's `init()`, so
/// any `Font.custom(...)` against an unregistered face silently bakes the
/// system fallback as the baseline. Call `ensureRegistered()` from every
/// snapshot suite that renders a bundled face.
@MainActor
enum SnapshotFontRegistration {
    private static let didEnsureFonts: Bool = {
        Core.registerBundledFonts()
        precondition(
            UIFont(name: "InstrumentSerif-Italic", size: 26) != nil,
            "Instrument Serif Italic failed to register — snapshots would bake the system-serif fallback"
        )
        precondition(
            UIFont(name: "JetBrainsMono-Regular", size: 10.5) != nil,
            "JetBrains Mono Regular failed to register — snapshots would bake the system-mono fallback"
        )
        return true
    }()

    static func ensureRegistered() {
        _ = didEnsureFonts
    }
}
#endif
