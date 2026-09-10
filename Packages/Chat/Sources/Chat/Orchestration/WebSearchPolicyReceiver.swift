import Foundation

public protocol WebSearchPolicyReceiver: Sendable {
    /// Idempotently apply the cost-gate policy to owned sessions.
    func setAskBeforeSearching(_ enabled: Bool) async
}

extension ChatSessionStore: WebSearchPolicyReceiver {}
