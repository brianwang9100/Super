import Core
@testable import Chat

// Test convenience equates configuration ID with upstream model ID. Keep this
// out of production, where multiple configurations can share a model. Tests
// exercising that distinction use init(recordId:model:) explicitly.
extension SelectableModel {
    init(_ model: LLMModel) {
        self.init(recordId: model.id, model: model)
    }
}
