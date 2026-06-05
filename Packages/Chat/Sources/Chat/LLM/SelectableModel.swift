import Core
import Foundation

/// A model the user can select in the composer or as the title summarizer,
/// identified by the **unique record id** (`recordId` == the registered
/// `LLMProvider.id` == `ModelConfigurationRecord.id`) paired with the
/// descriptor the provider vends.
///
/// Selection keys on `recordId`, never `model.id`: `model.id` is the upstream
/// model string (`gpt-4o`, `claude-opus-4-7`), and two BYOK rows may share it
/// (the model-configuration table has no UNIQUE constraint on `modelId`; its
/// primary key is `id`). The record id is the only identity guaranteed unique
/// per configured model, and it's what `LLMProviderRegistry.setActive(id:)` /
/// `provider(id:)` already key on — so storing it lets a selection resolve to
/// exactly one provider with no scan. (Provider→model is 1:1: each provider
/// vends a single `supportedModels` entry.)
public struct SelectableModel: Identifiable, Sendable, Equatable {
    /// Unique configured-model identity: the registered provider's id, equal to
    /// the source `ModelConfigurationRecord.id`.
    public let recordId: String
    /// The descriptor the provider vends (display name, context window, etc.).
    public let model: LLMModel

    /// `Identifiable` conformance keys on the unique `recordId`.
    public var id: String { recordId }

    public init(recordId: String, model: LLMModel) {
        self.recordId = recordId
        self.model = model
    }

    /// Pair each registered provider with the single model it vends —
    /// provider→model is 1:1, so a provider exposing nothing is skipped. The
    /// one home for the "first model per provider" rule, shared by the composer
    /// (`AppShell`) and the title path (`TitleGenerator`).
    public static func from(providers: [any LLMProvider]) -> [SelectableModel] {
        providers.compactMap { provider in
            provider.supportedModels.first.map {
                SelectableModel(recordId: provider.id, model: $0)
            }
        }
    }
}
