import Core
import Foundation

/// Uses the configuration record ID because multiple BYOK rows may share one wire model ID.
public struct SelectableModel: Identifiable, Sendable, Equatable {
    public let recordId: String
    public let model: LLMModel

    public var id: String { recordId }

    public init(recordId: String, model: LLMModel) {
        self.recordId = recordId
        self.model = model
    }

    /// Providers vend at most one configured model on this path.
    public static func from(providers: [any LLMProvider]) -> [SelectableModel] {
        providers.compactMap { provider in
            provider.supportedModels.first.map {
                SelectableModel(recordId: provider.id, model: $0)
            }
        }
    }
}
