import Foundation
import Observation

/// Ordered, composition-root-populated catalog of every `MiniApplet` installed
/// in this build of Super. Exposes the active applet identifier as observable
/// state so the shell's `body` re-renders the backdrop when the user switches
/// applets from the sidebar.
///
/// Mutation surface is intentionally small: the composition root builds the
/// registry once with the static applet list; runtime code only flips
/// `activeID`. Dynamic install / uninstall flows (`docs/DESIGN.md §3.2-3.3`)
/// will grow `register(_:)` / `unregister(_:)` later; today we don't need
/// them.
@Observable
@MainActor
public final class AppletRegistry {
    /// Display order matches the order passed at construction. The sidebar
    /// renders these top-to-bottom in that order.
    public let applets: [any MiniApplet]

    /// Identifier of the applet currently rendered behind the chat overlay.
    /// Mutating triggers re-render in any view that reads it (sidebar's
    /// active highlight, the shell's backdrop layer). `nil` would mean "no
    /// backdrop"; the shipped shell always seeds this from persisted state
    /// at init so it never goes nil in production — kept optional only to
    /// model the empty-registry edge case for tests.
    public var activeID: String?

    public init(applets: [any MiniApplet], initialActiveID: String? = nil) {
        self.applets = applets
        // `initialActiveID` defaults to `nil` for tests / empty-registry
        // callers; the shipped shell always supplies an explicit ID seeded
        // from persisted state so the backdrop layer never renders empty.
        self.activeID = initialActiveID
    }

    /// Returns the currently active applet, or `nil` if `activeID` doesn't
    /// match any registered applet (only happens if the caller mutated to a
    /// stale id; the shell falls back to the first applet in that case).
    public var activeApplet: (any MiniApplet)? {
        guard let activeID else { return nil }
        return applets.first { $0.appletID == activeID }
    }

}
