import SwiftUI

/// A settings surface an applet contributes to the shared Settings screen
/// **without the host importing the applet**. The host (Chat's Settings) renders
/// a generic row from the descriptor and routes to `makeDestination()` — an
/// opaque `AnyView` the applet builds — so e.g. Bible can own an "Annotations"
/// pane reached from Settings while the no-cross-applet-import rule holds.
///
/// The composition root constructs these (it's the one place that imports every
/// applet) and injects them via `\.appletSettingsContributions`.
public struct AppletSettingsContribution: Identifiable {
    public let id: String
    /// Row label, e.g. "Annotations".
    public let label: String
    /// Leading row glyph, supplied by the applet so it matches its own iconography.
    public let icon: AnyView
    /// Trailing value text (e.g. coverage "3 books"), recomputed per render.
    public let makeValue: @MainActor () -> String?
    /// The pane pushed when the row is tapped.
    public let makeDestination: @MainActor () -> AnyView

    public init(
        id: String,
        label: String,
        icon: AnyView,
        value: @escaping @MainActor () -> String? = { nil },
        destination: @escaping @MainActor () -> AnyView
    ) {
        self.id = id
        self.label = label
        self.icon = icon
        self.makeValue = value
        self.makeDestination = destination
    }
}

/// Environment slot carrying the applet-contributed settings surfaces. Empty by
/// default (so previews/tests render the base Settings); the composition root
/// sets the real list.
public struct AppletSettingsContributionsKey: EnvironmentKey {
    public static var defaultValue: [AppletSettingsContribution] { [] }
}

public extension EnvironmentValues {
    var appletSettingsContributions: [AppletSettingsContribution] {
        get { self[AppletSettingsContributionsKey.self] }
        set { self[AppletSettingsContributionsKey.self] = newValue }
    }
}
