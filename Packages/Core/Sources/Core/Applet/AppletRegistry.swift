import Foundation
import Observation

@Observable
@MainActor
public final class AppletRegistry {
    /// Display order matches construction order.
    public let applets: [any MiniApplet]

    /// `nil` models an empty registry; production shells seed a valid identifier.
    public var activeID: String?

    /// Returns a registered `storedID`, otherwise the caller's order-independent
    /// cold-start fallback. The fallback itself must identify a registered applet.
    public static func resolveActiveID(
        applets: [any MiniApplet],
        storedID: String?,
        fallbackID: String
    ) -> String {
        applets.first(where: { $0.appletID == storedID })?.appletID ?? fallbackID
    }

    public init(applets: [any MiniApplet], initialActiveID: String? = nil) {
        self.applets = applets
        self.activeID = initialActiveID
    }

    public var activeApplet: (any MiniApplet)? {
        guard let activeID else { return nil }
        return applets.first { $0.appletID == activeID }
    }

    /// Nonempty, trimmed briefings sorted by appletID for a stable cache prefix.
    /// Empty compact prompts fall back to the full body.
    public func resolvedBriefings() -> [AppletBriefing] {
        applets
            .sorted { $0.appletID < $1.appletID }
            .compactMap { applet -> AppletBriefing? in
                let trimmed = applet.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let trimmedCompact = applet.compactSystemPrompt
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return AppletBriefing(
                    label: "\(applet.displayName) applet",
                    body: trimmed,
                    compactBody: trimmedCompact.isEmpty ? nil : trimmedCompact,
                    appletID: applet.appletID
                )
            }
    }
}
