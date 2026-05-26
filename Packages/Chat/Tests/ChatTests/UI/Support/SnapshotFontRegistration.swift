#if canImport(UIKit)
import Core
import UIKit

/// One-time setup that registers the bundled brand fonts shipped in
/// `Core.Bundle.module` (Instrument Serif Italic + JetBrains Mono Regular)
/// and hard-fails if either face fails to land.
///
/// The xctest process never invokes `SuperOSApp.init()` / `SuperBibleApp.init()`,
/// so the bundled `.ttf`s are unregistered by default. Any `Font.custom(...)`
/// against an unregistered face silently falls back to a system face — and
/// a snapshot recorded in that state bakes the wrong glyphs as the
/// source of truth.
///
/// Every Chat snapshot suite that renders a bundled face — directly
/// (`ContextMeter`'s JetBrains Mono caption, `ChatEmptyState`'s Instrument
/// Serif greeting, `ChatsScreen`'s Instrument Serif title) or transitively
/// (anything embedding `ChatComposer` / `ChatScreen` / `ChatEmptyState`) —
/// must call `ensureRegistered()` from its `init()`. Calling from only
/// some suites would create a parallel-execution race: registration is
/// process-global, so the *first* suite to register changes every
/// later-running suite's rendering. Every suite calling it makes the
/// rendering deterministic regardless of run order.
///
/// The actual font-registration work + `UIFont` preconditions run **once**
/// across the test process via the lazy static let; every later
/// `ensureRegistered()` call just reads a cached `Bool`. Per-suite init
/// overhead is therefore negligible, which matters because Swift Testing
/// shares the main actor across `@MainActor` suites — a non-trivial init
/// on the snapshot suites would steal main-actor time from event-bus
/// tests whose async assertions have tight (1-second) timeouts.
@MainActor
enum SnapshotFontRegistration {
    /// Marker that proves the lazy init body ran. Reading this from
    /// `ensureRegistered()` triggers the body exactly once.
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

    /// Cheap, idempotent: forces the lazy `didEnsureFonts` initializer
    /// to run on first call, no-ops on every later call.
    static func ensureRegistered() {
        _ = didEnsureFonts
    }
}
#endif
