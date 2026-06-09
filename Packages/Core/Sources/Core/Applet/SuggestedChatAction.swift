import SwiftUI

/// A ready-made chat prompt an applet contributes to the chat empty state —
/// rendered as a tappable button that sends `message` when tapped. Each applet
/// owns its own actions (Bible contributes Bible prompts, Todo contributes Todo
/// prompts); the composition root aggregates them across the registered applet
/// set, so each target shows exactly the actions for the applets it ships.
///
/// `label` is the short button text; `message` is the (possibly fuller) prompt
/// sent to the assistant.
public struct SuggestedChatAction: Identifiable, Sendable, Equatable {
    public let label: String
    public let message: String

    /// `label` is the visible, de-dupe, and `ForEach` key — keep labels unique
    /// within an applet (cross-applet collisions are dropped by `merged`).
    public var id: String { label }

    public init(label: String, message: String) {
        self.label = label
        self.message = message
    }

    /// Flatten per-applet lists in registration order, drop later duplicates by
    /// `label`, and cap to `limit` for display. Pure so the shell's aggregation
    /// is unit-tested without spinning up applets.
    public static func merged(_ lists: [[SuggestedChatAction]], limit: Int = 4) -> [SuggestedChatAction] {
        var seen = Set<String>()
        var result: [SuggestedChatAction] = []
        for action in lists.flatMap({ $0 }) where seen.insert(action.label).inserted {
            result.append(action)
            if result.count == limit { break }
        }
        return result
    }
}

/// Environment slot carrying the applet-contributed chat actions, aggregated by
/// the composition root. Empty by default (previews/tests render no buttons).
public struct AppletSuggestedChatActionsKey: EnvironmentKey {
    public static var defaultValue: [SuggestedChatAction] { [] }
}

public extension EnvironmentValues {
    var appletSuggestedChatActions: [SuggestedChatAction] {
        get { self[AppletSuggestedChatActionsKey.self] }
        set { self[AppletSuggestedChatActionsKey.self] = newValue }
    }
}
