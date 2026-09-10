import SwiftUI

public struct SuggestedChatAction: Identifiable, Sendable, Equatable {
    public let label: String
    public let message: String

    /// Labels must be unique within an applet: they are the ForEach and deduplication key.
    public var id: String { label }

    public init(label: String, message: String) {
        self.label = label
        self.message = message
    }

    /// Preserves registration order, dropping later duplicate labels before applying the limit.
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

public struct AppletSuggestedChatActionsKey: EnvironmentKey {
    public static var defaultValue: [SuggestedChatAction] { [] }
}

public extension EnvironmentValues {
    var appletSuggestedChatActions: [SuggestedChatAction] {
        get { self[AppletSuggestedChatActionsKey.self] }
        set { self[AppletSuggestedChatActionsKey.self] = newValue }
    }
}
