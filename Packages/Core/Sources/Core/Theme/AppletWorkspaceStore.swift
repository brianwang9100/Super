import Observation
import SwiftUI

public enum AppletWorkspacePresentation: Sendable, Equatable {
    case singleSurface
    case companion
}

@MainActor
@Observable
public final class AppletWorkspaceStore {
    public var requestedPresentation: AppletWorkspacePresentation = .singleSurface
    public private(set) var isCompanionPresented = false

    public init() {}

    public func updateAvailableWidth(_ width: CGFloat, textScale: CGFloat) {
        isCompanionPresented = requestedPresentation == .companion
            && Self.supportsCompanion(width: width, textScale: textScale)
    }

    public static func supportsCompanion(width: CGFloat, textScale: CGFloat) -> Bool {
        width >= (360 + 380) * max(1, textScale) + 24 + 48
    }
}

private struct AppletWorkspaceStoreKey: EnvironmentKey {
    static let defaultValue: AppletWorkspaceStore? = nil
}

public extension EnvironmentValues {
    var appletWorkspaceStore: AppletWorkspaceStore? {
        get { self[AppletWorkspaceStoreKey.self] }
        set { self[AppletWorkspaceStoreKey.self] = newValue }
    }
}
