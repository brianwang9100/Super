import SwiftUI

public struct ChatComposerFooter: View {
    public let modelOptions: [ModelPill.Option]
    public let selectedModelId: String?
    public let onSelectModel: (String) -> Void
    public let onManageModels: () -> Void
    public let usedTokens: Int
    public let maxTokens: Int

    public init(
        modelOptions: [ModelPill.Option],
        selectedModelId: String?,
        onSelectModel: @escaping (String) -> Void,
        onManageModels: @escaping () -> Void = {},
        usedTokens: Int,
        maxTokens: Int
    ) {
        self.modelOptions = modelOptions
        self.selectedModelId = selectedModelId
        self.onSelectModel = onSelectModel
        self.onManageModels = onManageModels
        self.usedTokens = usedTokens
        self.maxTokens = maxTokens
    }

    public var body: some View {
        HStack(spacing: 4) {
            ModelPill(
                options: modelOptions,
                selectedId: selectedModelId,
                onSelect: onSelectModel,
                onManageModels: onManageModels
            )
            Spacer(minLength: 0)
            ContextMeter(usedTokens: usedTokens, maxTokens: maxTokens)
        }
    }
}
