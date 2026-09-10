import SwiftUI

/// The composition root injects these so Settings can host applet-owned views
/// without importing another applet.
public struct AppletSettingsContribution: Identifiable {
    public let id: String
    public let label: String
    public let icon: AnyView
    /// Recomputed per render.
    public let makeValue: @MainActor () -> String?
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

public struct AppletSettingsContributionsKey: EnvironmentKey {
    public static var defaultValue: [AppletSettingsContribution] { [] }
}

public extension EnvironmentValues {
    var appletSettingsContributions: [AppletSettingsContribution] {
        get { self[AppletSettingsContributionsKey.self] }
        set { self[AppletSettingsContributionsKey.self] = newValue }
    }
}
