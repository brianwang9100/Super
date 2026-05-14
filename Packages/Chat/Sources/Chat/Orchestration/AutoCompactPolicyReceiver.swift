import Foundation

/// Seam between the Settings UI and the orchestration layer for
/// auto-compaction policy fan-out. `ChatSessionStore` is the production
/// conformer; tests substitute a fake so `SettingsViewModel` can be
/// exercised without constructing the whole orchestration graph (repos,
/// compactor, registries). Per AGENTS.md §Testing §1, settings consumers
/// must reach the orchestration layer through a protocol — never the
/// concrete actor.
public protocol AutoCompactPolicyReceiver: Sendable {
    /// Apply `(enabled, threshold)` as the new auto-compaction policy,
    /// propagating to any state the receiver owns. Idempotent / safe to
    /// call with the current pair — receivers are expected to no-op in
    /// that case. The threshold is a fraction of `model.maxContextTokens`
    /// in the same shape as `ContextAssembly.isOverThreshold`.
    func setAutoCompactPolicy(enabled: Bool, threshold: Double) async
}

extension ChatSessionStore: AutoCompactPolicyReceiver {}
