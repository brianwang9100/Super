import Observation
import SwiftUI

/// Applets reserve a bottom control region shared with the shell's sibling Chat layers.
@MainActor
@Observable
public final class BottomControlOccupancyStore {
    public var isOccupied = false
    public var measuredHeight: CGFloat = 0
    public init() {}
}

private struct BottomControlOccupancyStoreKey: EnvironmentKey {
    static let defaultValue: BottomControlOccupancyStore? = nil
}

public extension EnvironmentValues {
    var bottomControlOccupancyStore: BottomControlOccupancyStore? {
        get { self[BottomControlOccupancyStoreKey.self] }
        set { self[BottomControlOccupancyStoreKey.self] = newValue }
    }
}
