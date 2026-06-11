import SwiftUI

/// Carries the app-wide ``HapticsEngine`` to pure view-layer tap sites (the
/// hamburger button, the sidebar applet/chat rows) that have no view model to
/// inject through. Defaults to a silent ``NoOpHapticsEngine`` so previews and
/// snapshot fixtures make no sound. Mirrors the `\.superFontScale` injection
/// pattern; view-model logic receives the engine by constructor instead.
private struct HapticsEngineKey: EnvironmentKey {
    static let defaultValue: any HapticsEngine = NoOpHapticsEngine()
}

public extension EnvironmentValues {
    /// The active app-wide haptics engine. Defaults to a no-op.
    var hapticsEngine: any HapticsEngine {
        get { self[HapticsEngineKey.self] }
        set { self[HapticsEngineKey.self] = newValue }
    }
}

public extension View {
    /// Inject the app-wide haptics engine into the environment for this
    /// subtree. Apply at the app shell's composition root alongside
    /// `.superTheme(_:)` / `.superFontScale(_:)`.
    func hapticsEngine(_ engine: any HapticsEngine) -> some View {
        environment(\.hapticsEngine, engine)
    }
}
