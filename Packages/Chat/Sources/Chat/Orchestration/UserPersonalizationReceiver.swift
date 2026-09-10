import Foundation

public protocol UserPersonalizationReceiver: Sendable {
    /// Idempotently apply personalization to owned state.
    func setUserPersonalization(_ value: String) async
}

extension ChatSessionStore: UserPersonalizationReceiver {}
