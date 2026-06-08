#if canImport(UIKit)
import Core
import Testing
import UIKit

/// One-time, process-global registration of `Core`'s bundled `.ttf` fonts
/// for snapshot tests. The xctest host never runs the app's `init()`, so
/// any `Font.custom(...)` against an unregistered face silently bakes the
/// system fallback as the baseline. Mirrors Chat's helper of the same name.
///
/// Call `ensureRegistered()` from every Bible snapshot suite that renders a
/// bundled brand face. After the reader's SuperTypography migration that's the
/// chapter title and the section headings (brand serif) — so the reader-driver
/// suites (`BibleChapterReaderSnapshotTests`, `BibleScreenSnapshotTests`) must
/// register, or their baselines bake the system fallback and the render drifts
/// from the real app. Registration is process-global, so a future suite that
/// renders a brand face must call this too: suite execution order is
/// non-deterministic, and a brand-face render that runs *before* any
/// registration would otherwise capture the fallback.
@MainActor
enum SnapshotFontRegistration {
    private static var verified = false

    static func ensureRegistered() {
        if verified { return }
        verified = true
        Core.registerBundledFonts()
        // Italic display (chapter title / headings) + roman reading (verse
        // body) + SemiBold (heading weight) must all register, or the reader
        // baselines bake the system-serif fallback.
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
