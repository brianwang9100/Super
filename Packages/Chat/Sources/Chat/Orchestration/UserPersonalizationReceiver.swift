import Foundation

/// Seam between the Settings UI and the orchestration layer for
/// user-personalization fan-out (renamed from the previous
/// `SystemPromptReceiver` when the user-editable system prompt was
/// reframed as personalization). `ChatSessionStore` is the production
/// conformer; tests substitute a fake so `SettingsViewModel` can be
/// exercised without constructing the whole orchestration graph
/// (repos, compactor, registries). Per AGENTS.md §Testing §1, settings
/// consumers must reach the orchestration layer through a protocol —
/// never the concrete actor.
public protocol UserPersonalizationReceiver: Sendable {
    /// Apply `value` as the new user-personalization text, propagating
    /// to any state the receiver owns. Idempotent / safe to call with
    /// the current value — receivers are expected to no-op in that
    /// case.
    func setUserPersonalization(_ value: String) async
}

extension ChatSessionStore: UserPersonalizationReceiver {}
