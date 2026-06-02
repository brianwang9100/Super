import Foundation

/// Seam between the Settings UI and the orchestration layer for the
/// native web-search cost gate ("Ask before each search"). `ChatSessionStore`
/// is the production conformer — it already exposes a matching
/// `setAskBeforeSearching(_:)` that fans the value out to every active
/// `ChatSession` and seeds sessions created afterward. Tests substitute a
/// fake so `SettingsViewModel` can be exercised without constructing the
/// whole orchestration graph (repos, compactor, registries). Per
/// AGENTS.md §Testing §1, settings consumers must reach the orchestration
/// layer through a protocol — never the concrete actor.
public protocol WebSearchPolicyReceiver: Sendable {
    /// Apply `enabled` as the new "ask before each search" policy,
    /// propagating to any state the receiver owns. Idempotent / safe to
    /// call with the current value — receivers are expected to no-op in
    /// that case.
    func setAskBeforeSearching(_ enabled: Bool) async
}

extension ChatSessionStore: WebSearchPolicyReceiver {}
