import SwiftUI

/// Footer row that lives inside the composer capsule. Lays out (in order):
/// `ModelPill` · flexible spacer · `ContextMeter` · trailing send/mic
/// button (the button itself lives in `ChatComposer`, not here, so the
/// composer can swap its enabled/disabled state without re-laying out
/// the row).
///
/// Verbosity is owned by Settings (see `SettingsVerbosityPane`); the
/// composer footer doesn't expose a per-chat picker.
///
/// Mirrors the bottom row of the composer in
/// `.design-tmp/chat/project/src/chat-view.jsx`.
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
