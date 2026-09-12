import Observation
import SwiftUI

/// A shell-owned slot for applet navigation above sibling content surfaces.
@MainActor
@Observable
public final class AppletNavigationChromeStore {
    public private(set) var ownerID: UUID?
    public private(set) var content: AnyView?
    public private(set) var measuredHeight: CGFloat = 0

    public init() {}

    public func install(ownerID: UUID, content: AnyView) {
        if self.ownerID != ownerID { measuredHeight = 0 }
        self.ownerID = ownerID
        self.content = content
    }

    @discardableResult
    public func update(ownerID: UUID, content: AnyView) -> Bool {
        guard self.ownerID == ownerID else { return false }
        self.content = content
        return true
    }

    public func measure(height: CGFloat, ownerID: UUID) {
        guard self.ownerID == ownerID else { return }
        measuredHeight = max(0, height)
    }

    public func remove(ownerID: UUID) {
        guard self.ownerID == ownerID else { return }
        self.ownerID = nil
        content = nil
        measuredHeight = 0
    }
}

private struct AppletNavigationChromeStoreKey: EnvironmentKey {
    static let defaultValue: AppletNavigationChromeStore? = nil
}

public extension EnvironmentValues {
    var appletNavigationChromeStore: AppletNavigationChromeStore? {
        get { self[AppletNavigationChromeStoreKey.self] }
        set { self[AppletNavigationChromeStoreKey.self] = newValue }
    }
}

public extension View {
    /// Keep the source mounted while the shell renders its navigation. Omit the store
    /// to leave placement to the applet. Content receives the shell's environment.
    func appletNavigationChrome<Navigation: View>(
        isPresented: Bool,
        @ViewBuilder content: () -> Navigation
    ) -> some View {
        modifier(AppletNavigationChromeModifier(isPresented: isPresented, navigation: AnyView(content())))
    }
}

private struct AppletNavigationChromeModifier: ViewModifier {
    @Environment(\.appletNavigationChromeStore) private var store
    @State private var ownerID = UUID()

    let isPresented: Bool
    let navigation: AnyView
    // Fresh source values refresh captured actions after the body evaluation, without
    // making the source observe the sibling host's content or spawning update tasks.
    private let revision = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { updatePresentation() }
            .onChange(of: isPresented) { _, _ in updatePresentation() }
            .onChange(of: revision) { _, _ in
                if isPresented { store?.update(ownerID: ownerID, content: navigation) }
            }
            .onDisappear { store?.remove(ownerID: ownerID) }
    }

    private func updatePresentation() {
        if isPresented {
            store?.install(ownerID: ownerID, content: navigation)
        } else {
            store?.remove(ownerID: ownerID)
        }
    }
}
