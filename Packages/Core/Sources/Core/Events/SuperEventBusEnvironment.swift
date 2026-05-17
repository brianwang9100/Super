import SwiftUI

/// Environment plumbing for the shared `SuperEventBus`. The shell injects a
/// single instance at the composition root; a `nil` default keeps tests and
/// previews — which have no bus — rendering without extra wiring. Mirrors
/// the `\.superFontScale` injection pattern.
private struct SuperEventBusKey: EnvironmentKey {
    static let defaultValue: SuperEventBus? = nil
}

public extension EnvironmentValues {
    /// The app-wide cross-applet event bus, or `nil` when no bus is wired.
    var superEventBus: SuperEventBus? {
        get { self[SuperEventBusKey.self] }
        set { self[SuperEventBusKey.self] = newValue }
    }
}

public extension View {
    /// Inject the cross-applet event bus into the environment for this
    /// subtree. Apply once at the composition root so every applet shares
    /// the same bus instance.
    func superEventBus(_ bus: SuperEventBus) -> some View {
        environment(\.superEventBus, bus)
    }
}
