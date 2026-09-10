import SwiftUI

/// Lets applets supply composer actions without passing views or domain types into Chat.
public struct ComposerAccessoryButton {
    public let systemImage: String
    public let accessibilityLabel: String
    public let isEnabled: Bool
    public let action: () -> Void

    public init(
        systemImage: String,
        accessibilityLabel: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.isEnabled = isEnabled
        self.action = action
    }
}

/// Nil slots render nothing; an entirely empty configuration removes the accessory row.
public struct ComposerAccessoryButtons {
    public let leading: ComposerAccessoryButton?
    public let trailing: ComposerAccessoryButton?
    public let selection: ComposerAccessorySelection?
    /// Hides only edge buttons; selection stays visible. Nil never hides them.
    /// Evaluated in the rendering body so reads of observable applet state remain reactive.
    public let shouldHideButtons: (() -> Bool)?

    public init(
        leading: ComposerAccessoryButton? = nil,
        trailing: ComposerAccessoryButton? = nil,
        selection: ComposerAccessorySelection? = nil,
        shouldHideButtons: (() -> Bool)? = nil
    ) {
        self.leading = leading
        self.trailing = trailing
        self.selection = selection
        self.shouldHideButtons = shouldHideButtons
    }

    // Computed because action closures make the descriptor non-Sendable global state.
    public static var none: ComposerAccessoryButtons { ComposerAccessoryButtons() }

    public var isEmpty: Bool { leading == nil && trailing == nil && selection == nil }
}

/// Inject one shell-owned instance above both applet and composer siblings.
/// A sibling cannot inherit the applet's environment, and the event bus cannot
/// carry live action closures. Omitting injection removes the accessory row.
@MainActor
@Observable
public final class ComposerAccessoryStore {
    public var buttons: ComposerAccessoryButtons = .none

    public init() {}
}

struct ComposerAccessoryStoreKey: EnvironmentKey {
    static let defaultValue: ComposerAccessoryStore? = nil
}

public extension EnvironmentValues {
    var composerAccessoryStore: ComposerAccessoryStore? {
        get { self[ComposerAccessoryStoreKey.self] }
        set { self[ComposerAccessoryStoreKey.self] = newValue }
    }
}

public extension View {
    func composerAccessoryStore(_ store: ComposerAccessoryStore?) -> some View {
        environment(\.composerAccessoryStore, store)
    }
}
