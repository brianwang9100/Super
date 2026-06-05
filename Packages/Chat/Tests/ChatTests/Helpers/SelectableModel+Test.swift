import Core
@testable import Chat

// MARK: - Tests / Previews only
//
// A convenience that defaults `recordId` to `model.id`, for the many test
// call sites where the record id isn't meaningfully distinct from the vended
// model id (one model per id). Deliberately kept out of the production target:
// using `model.id` as the record id in a real path would reintroduce the
// shared-`modelId` selection bug this type exists to prevent. Tests that
// exercise the distinction construct `SelectableModel(recordId:model:)`
// explicitly.
extension SelectableModel {
    init(_ model: LLMModel) {
        self.init(recordId: model.id, model: model)
    }
}
