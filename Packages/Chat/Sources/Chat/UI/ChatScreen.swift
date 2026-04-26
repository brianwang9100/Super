import SwiftUI

/// Top-level chat surface: header on top, transcript or empty state in the
/// middle, composer pinned to the bottom. Owned by the App composition
/// root which constructs the view model with the live `AppDependencies`.
///
/// The hamburger menu button forwards to `onMenuTap` (`SidebarDrawer` is
/// M8 — until then the host wires it to a no-op or a debug print).
public struct ChatScreen: View {
    @Bindable public var viewModel: ChatScreenViewModel
    public let onMenuTap: () -> Void

    public init(
        viewModel: ChatScreenViewModel,
        onMenuTap: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.onMenuTap = onMenuTap
    }

    @Environment(\.superTheme) private var theme

    public var body: some View {
        VStack(spacing: 0) {
            ChatHeader(title: viewModel.headerTitle, onMenuTap: onMenuTap)
            content
                .frame(maxHeight: .infinity)
            ChatComposer(
                text: $viewModel.composerText,
                isStreaming: viewModel.isStreaming,
                modelOptions: viewModel.modelOptions,
                selectedModelId: viewModel.selectedModelId,
                onSelectModel: { viewModel.selectedModelId = $0 },
                verbosity: viewModel.verbosity,
                onSelectVerbosity: { viewModel.verbosity = $0 },
                usedTokens: viewModel.usedTokens,
                maxTokens: viewModel.maxContextTokens,
                onSubmit: viewModel.send,
                onMicTap: {
                    // M11 wires `SpeechRecognizerVoiceInputService` here.
                },
                onCancelStreaming: viewModel.cancelStreaming
            )
        }
        .background(theme.background.ignoresSafeArea())
        .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.items.isEmpty && viewModel.streamingTail == nil {
            ChatEmptyStateView()
        } else {
            MessageListView(
                items: viewModel.items,
                streamingTail: viewModel.streamingTail,
                error: viewModel.error,
                verbosity: viewModel.verbosity,
                onRetry: viewModel.retry
            )
        }
    }
}
