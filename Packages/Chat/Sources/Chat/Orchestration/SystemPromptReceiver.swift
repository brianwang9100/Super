import Foundation

/// Seam between the Settings UI and the orchestration layer for system-
/// prompt fan-out. `ChatSessionStore` is the production conformer; tests
/// substitute a fake so `SettingsViewModel` can be exercised without
/// constructing the whole orchestration graph (repos, compactor,
/// registries). Per AGENTS.md §Testing §1, settings consumers must reach
/// the orchestration layer through a protocol — never the concrete actor.
public protocol SystemPromptReceiver: Sendable {
    /// Apply `value` as the new system prompt, propagating to any state
    /// the receiver owns. Idempotent / safe to call with the current
    /// value — receivers are expected to no-op in that case.
    func setSystemPrompt(_ value: String) async
}

extension ChatSessionStore: SystemPromptReceiver {}
