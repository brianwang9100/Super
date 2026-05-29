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

    /// Resolves which applet should be the active backdrop at launch.
    ///
    /// Prefers `storedID` (the persisted selection) when it still matches a
    /// registered applet; otherwise returns `fallbackID`. The fallback is the
    /// caller's explicit cold-start default and is **independent of the
    /// `applets` array order** — so the sidebar rail can list applets in any
    /// order without moving the fresh-install landing surface. The composition
    /// root passes the persisted `UserDefaults` value as `storedID` (kept out
    /// of here so this resolution stays a pure, testable function).
    ///
    /// - Parameters:
    ///   - applets: The registered applets, in sidebar order.
    ///   - storedID: The persisted active id, or `nil` on a fresh install.
    ///   - fallbackID: The cold-start default returned verbatim when `storedID`
    ///     is `nil` or no longer matches a registered applet. Callers must pass
    ///     a `fallbackID` that is itself a registered applet, otherwise the
    ///     returned id won't resolve to a backdrop (`activeApplet` is `nil`).
    /// - Returns: The persisted id when it matches a registered applet, else
    ///   `fallbackID`.
    public static func resolveActiveID(
        applets: [any MiniApplet],
        storedID: String?,
        fallbackID: String
    ) -> String {
        applets.first(where: { $0.appletID == storedID })?.appletID ?? fallbackID
    }

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

    /// Returns one `AppletBriefing` per registered applet whose
    /// `systemPrompt` is non-empty (after trimming), sorted by `appletID`
    /// so the Anthropic prompt-cache prefix is stable across turns even
    /// if the shell ever re-orders the applet list at launch. The label
    /// is `"\(displayName) applet"`; the body is the trimmed prompt text.
    public func resolvedBriefings() -> [AppletBriefing] {
        applets
            .sorted { $0.appletID < $1.appletID }
            .compactMap { applet -> AppletBriefing? in
                let trimmed = applet.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return AppletBriefing(
                    label: "\(applet.displayName) applet",
                    body: trimmed
                )
            }
    }

}
