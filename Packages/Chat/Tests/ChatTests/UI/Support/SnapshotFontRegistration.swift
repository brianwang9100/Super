#if canImport(UIKit)
import Core
import Testing
import UIKit

// The test host skips app initialization. Register fonts before rendering
// each suite so missing faces cannot silently produce fallback baselines.
@MainActor
enum SnapshotFontRegistration {
    private static var verified = false

    static func ensureRegistered() {
        if verified { return }
        verified = true
        Core.registerBundledFonts()
        for face in ["EBGaramond-Italic", "EBGaramond-Regular", "EBGaramond-SemiBold"] {
            if UIFont(name: face, size: 26) == nil {
                Issue.record("\(face) failed to register — snapshots would bake the system-serif fallback")
            }
        }
        if UIFont(name: "JetBrainsMono-Regular", size: 10.5) == nil {
            Issue.record("JetBrains Mono Regular failed to register — snapshots would bake the system-mono fallback")
        }
    }
}
#endif
