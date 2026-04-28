import SwiftUI

/// Footer row that lives inside the composer capsule. Lays out (in order):
/// `ModelPill` · `VerbosityPill` · flexible spacer · `ContextMeter` ·
/// trailing send/mic button (the button itself lives in `ChatComposer`,
/// not here, so the composer can swap its enabled/disabled state without
/// re-laying out the row).
///
/// Mirrors the bottom row of the composer in
/// `.design-tmp/chat/project/src/chat-view.jsx`.
public struct ChatComposerFooter: View {
    public let modelOptions: [ModelPill.Option]
    public let selectedModelId: String?
    public let onSelectModel: (String) -> Void
    public let onManageModels: () -> Void
    public let verbosity: ChatVerbosity
    public let onSelectVerbosity: (ChatVerbosity) -> Void
    public let usedTokens: Int
    public let maxTokens: Int

    public init(
        modelOptions: [ModelPill.Option],
        selectedModelId: String?,
        onSelectModel: @escaping (String) -> Void,
        onManageModels: @escaping () -> Void = {},
        verbosity: ChatVerbosity,
        onSelectVerbosity: @escaping (ChatVerbosity) -> Void,
        usedTokens: Int,
        maxTokens: Int
    ) {
        self.modelOptions = modelOptions
        self.selectedModelId = selectedModelId
        self.onSelectModel = onSelectModel
        self.onManageModels = onManageModels
        self.verbosity = verbosity
        self.onSelectVerbosity = onSelectVerbosity
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
            VerbosityPill(verbosity: verbosity, onSelect: onSelectVerbosity)
            Spacer(minLength: 0)
            ContextMeter(usedTokens: usedTokens, maxTokens: maxTokens)
        }
    }
}
