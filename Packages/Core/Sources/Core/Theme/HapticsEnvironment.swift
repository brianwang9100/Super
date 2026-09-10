import SwiftUI

/// Defaults to silence so previews and snapshots never produce haptics.
private struct HapticsEngineKey: EnvironmentKey {
    static let defaultValue: any HapticsEngine = NoOpHapticsEngine()
}

public extension EnvironmentValues {
    var hapticsEngine: any HapticsEngine {
        get { self[HapticsEngineKey.self] }
        set { self[HapticsEngineKey.self] = newValue }
    }
}

public extension View {
    func hapticsEngine(_ engine: any HapticsEngine) -> some View {
        environment(\.hapticsEngine, engine)
    }
}
