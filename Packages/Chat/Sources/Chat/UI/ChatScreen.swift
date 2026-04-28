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
    /// Tapped when the user picks "Manage models…" from the composer's
    /// model dropdown. The host typically opens the Settings sheet
    /// pre-routed to the Models pane.
    public let onManageModels: () -> Void

    public init(
        viewModel: ChatScreenViewModel,
        onMenuTap: @escaping () -> Void = {},
        onManageModels: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.onMenuTap = onMenuTap
        self.onManageModels = onManageModels
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
                onManageModels: onManageModels,
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
        // Bind the load to the conversation id so swapping the view
        // model when the user picks a different chat from the sidebar
        // re-fires `load()` against the new transcript. A bare `.task`
        // (no id) only fires on first appear — switching chats would
        // otherwise leave the new view model unloaded and the surface
        // stuck on the empty state.
        .task(id: viewModel.conversationId) { await viewModel.load() }
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
