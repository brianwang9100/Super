import Foundation

public protocol AutoCompactPolicyReceiver: Sendable {
    /// Idempotently apply policy to owned sessions. Threshold is a fraction of maxContextTokens.
    func setAutoCompactPolicy(enabled: Bool, threshold: Double) async
}

extension ChatSessionStore: AutoCompactPolicyReceiver {}
