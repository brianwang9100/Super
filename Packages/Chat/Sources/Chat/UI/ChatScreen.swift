import Core
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public struct ChatScreen: View {
    @Bindable public var viewModel: ChatScreenViewModel
    public let onManageModels: () -> Void

    /// Zero is the minimized pill; one is fully expanded. Drive continuously from overlay height.
    public let progress: Double

    public let onSurfaceTapped: (() -> Void)?

    public let onMinimize: (() -> Void)?

    /// Screen-space translation from either handle or the transcript body drag.
    public let onDragChanged: ((_ translation: CGSize) -> Void)?

    /// Final and predicted screen-space translations; the host uses the prediction to choose a resting state.
    public let onDragEnded: ((_ translation: CGSize, _ predictedEndTranslation: CGSize) -> Void)?

    private let dragResetToken: Int

    /// Prefer the shell's shared focus binding; use local focus for standalone hosts.
    private let externalComposerIsFocused: FocusState<Bool>.Binding?

    private let topSafeAreaInset: CGFloat

    @MainActor
    public init(
        viewModel: ChatScreenViewModel,
        progress: Double = 1,
        topSafeAreaInset: CGFloat = 0,
        composerIsFocused: FocusState<Bool>.Binding? = nil,
        onManageModels: @escaping () -> Void = {},
        onAddModelRequested: @escaping @MainActor @Sendable () -> Void = {},
        onSurfaceTapped: (() -> Void)? = nil,
        onMinimize: (() -> Void)? = nil,
        onDragChanged: ((_ translation: CGSize) -> Void)? = nil,
        onDragEnded: ((_ translation: CGSize, _ predictedEndTranslation: CGSize) -> Void)? = nil,
        dragResetToken: Int = 0
    ) {
        self.viewModel = viewModel
        self.progress = progress
        self.topSafeAreaInset = topSafeAreaInset
        self.externalComposerIsFocused = composerIsFocused
        self.onManageModels = onManageModels
        self.onSurfaceTapped = onSurfaceTapped
        self.onMinimize = onMinimize
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
        self.dragResetToken = dragResetToken
        viewModel.onAddModelRequested = onAddModelRequested
    }

    @Environment(\.superTheme) private var theme
    @Environment(\.pasteboardClient) private var pasteboard
    @Environment(\.superEventBus) private var superEventBus
    @Environment(\.appletSuggestedChatActions) private var suggestedChatActions
    @FocusState private var internalComposerIsFocused: Bool

    private var composerIsFocused: FocusState<Bool>.Binding {
        externalComposerIsFocused ?? $internalComposerIsFocused
    }

    private var headerProgress: Double {
        Self.smoothstep(progress, from: 0.6, to: 0.95)
    }

    private static let headerIntrinsicHeight: CGFloat = 38

    private var contentOpacity: Double {
        Self.smoothstep(progress, from: 0.15, to: 0.45)
    }

    private var pillSurfaceCaptureActive: Bool {
        progress <= ChatPresentationState.editorInteractiveThreshold
    }

    private var panelSurroundOpacity: Double {
        let fadeIn = Self.smoothstep(progress, from: 0, to: 0.1)
        let fadeOut = 1 - Self.smoothstep(progress, from: 0.9, to: 1.0)
        return fadeIn * fadeOut
    }

    private var surfaceBackgroundOpacity: Double {
        Self.smoothstep(progress, from: 0, to: 0.1)
    }

    private var panelCornerRadius: CGFloat {
        24 * (1 - Self.smoothstep(progress, from: 0.9, to: 1.0))
    }

    private var panelHorizontalInset: CGFloat {
        6 * (1 - Self.smoothstep(progress, from: 0.9, to: 1.0))
    }

    /// Bleed vertically for the composer shadow in pill/full-screen states.
    /// Horizontal bleed would visibly squeeze the card during the morph.
    private var verticalMaskBleed: CGFloat {
        160 * (1 - panelSurroundOpacity)
    }

    private var bottomSafeAreaFillOpacity: Double {
        Self.smoothstep(progress, from: 0.95, to: 1.0)
    }

    private static let topEdgeFadeTail: CGFloat = 40

    private var topEdgeFadeOpacity: Double {
        Self.smoothstep(progress, from: 0.95, to: 1.0)
    }

    /// Cover the status-bar strip so full expansion does not expose a seam of applet backdrop.
    @ViewBuilder
    private var topEdgeFade: some View {
        let total = topSafeAreaInset + Self.topEdgeFadeTail
        let solidFraction = total > 0 ? topSafeAreaInset / total : 0
        LinearGradient(
            stops: [
                .init(color: theme.background, location: 0),
                .init(color: theme.background, location: solidFraction),
                .init(color: theme.background.opacity(0), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(maxWidth: .infinity)
        .frame(height: total)
        .opacity(topEdgeFadeOpacity)
        .allowsHitTesting(false)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var regenerationDialogTitle: String {
        viewModel.pendingRegenerationDeleteCount <= 1
            ? "Regenerate this response?"
            : "Regenerate from here?"
    }

    private var regenerationDialogMessage: String {
        let count = viewModel.pendingRegenerationDeleteCount
        if count <= 1 {
            return "This response will be replaced."
        }
        let later = count - 1
        let plural = later == 1 ? "message" : "messages"
        return "This response and \(later) later \(plural) will be deleted."
    }

    private var regenerationDialogIsPresented: Binding<Bool> {
        Binding(
            get: { viewModel.pendingRegenerationTargetID != nil },
            set: { newValue in
                if !newValue {
                    viewModel.cancelRegeneration()
                }
            }
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Keep the drag host mounted across the morph so crossing thresholds cannot cancel the gesture.
            ChatDragHandle(
                onDragChanged: onDragChanged,
                onDragEnded: onDragEnded
            )
            ChatHeader(title: viewModel.headerTitle)
                .scaleEffect(headerProgress, anchor: .top)
                .opacity(headerProgress)
                .frame(height: CGFloat(headerProgress) * Self.headerIntrinsicHeight, alignment: .top)
                .clipped()
            content
                // Remove the intrinsic height floor so content cannot push the composer upward mid-drag.
                .frame(minHeight: 0, maxHeight: .infinity)
                .opacity(contentOpacity)
                // Dismiss only from transcript/empty-state taps so floating navigation and composer taps retain focus.
                .contentShape(Rectangle())
                // Place the scroll-edge resize handoff before the composer inset so composer gestures remain independent.
                .overlayContentDrag(
                    // At an endpoint, let the transcript scroll instead of handing off to a no-op resize.
                    canExpand: progress < 0.999,
                    canCollapse: progress > 0.001,
                    resetToken: dragResetToken,
                    onChanged: { translation in onDragChanged?(translation) },
                    onEnded: { translation, predicted in onDragEnded?(translation, predicted) }
                )
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    composer
                }
                // Clipping here would crop the composer shadow. The transcript clips itself; the panel mask contains the card.
        }
        .background(panelBackground)
        // Mask without changing layout width so text does not reflow through the morph.
        // The crop is cosmetic; hit testing retains the full surface.
        .mask {
            RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                .padding(.horizontal, panelHorizontalInset)
                .padding(.vertical, -verticalMaskBleed)
        }
        .overlay {
            RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                .strokeBorder(theme.borderFaint, lineWidth: 1)
                .padding(.horizontal, panelHorizontalInset)
                .opacity(panelSurroundOpacity)
        }
        .shadow(color: Color.black.opacity(0.18 * panelSurroundOpacity), radius: 12, x: 0, y: 12)
        .shadow(color: Color.black.opacity(0.12 * panelSurroundOpacity), radius: 30, x: 0, y: 30)
        .background(homeIndicatorFill)
        // Apply after the panel mask so the status-bar fade spans the full width at expansion.
        .overlay(alignment: .top) { topEdgeFade }
        .bibleDeepLinkRouting(eventBus: superEventBus)
        .confirmationDialog(
            regenerationDialogTitle,
            isPresented: regenerationDialogIsPresented,
            titleVisibility: .visible
        ) {
            Button("Regenerate", role: .destructive) {
                viewModel.confirmRegeneration()
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelRegeneration()
            }
        } message: {
            Text(regenerationDialogMessage)
        }
        // Conversation identity must restart loading even when this view remains mounted.
        .task(id: viewModel.conversationId) {
            viewModel.adoptPendingReferences()
            await viewModel.load()
        }
        // Disabling the editor leaves FocusState set; clear it on collapse to prevent a wedged or reopened keyboard.
        .onChange(of: progress) { oldValue, newValue in
            if ChatPresentationState.crossedBelowEditorThreshold(from: oldValue, to: newValue) {
                dismissKeyboard()
            }
        }
        .onChange(of: viewModel.isStreaming) { _, isStreaming in
            if isStreaming { dismissKeyboard() }
        }
        .onChange(of: viewModel.inboxPendingCount) { _, _ in
            viewModel.adoptPendingReferences()
        }
    }

    @ViewBuilder
    private var composer: some View {
        ChatComposer(
            text: composerBinding,
            isFocused: composerIsFocused,
            isStreaming: viewModel.isStreaming,
            modelOptions: viewModel.modelOptions,
            selectedModelId: viewModel.selectedModelId,
            onSelectModel: { viewModel.selectedModelId = $0 },
            onManageModels: onManageModels,
            usedTokens: viewModel.usedTokens,
            maxTokens: viewModel.maxContextTokens,
            onSubmit: viewModel.send,
            onMicTap: {
                Task { await viewModel.handleMicTap() }
            },
            onCancelStreaming: viewModel.cancelStreaming,
            isRecording: viewModel.voiceState.isRecording,
            isMicAvailable: viewModel.voiceState != .unavailable,
            onStopRecording: viewModel.handleStopRecording,
            onMinimize: onMinimize.map { action in
                {
                    dismissKeyboard()
                    action()
                }
            },
            onDragChanged: onDragChanged,
            onDragEnded: onDragEnded,
            progress: progress,
            references: viewModel.pendingReferences.map {
                VerseReferencePillModel(id: $0.id, label: $0.displayLabel)
            },
            onRemoveReference: viewModel.removeReference
        )
        .overlay {
            if pillSurfaceCaptureActive {
                pillSurfaceCapture
            }
        }
    }

    @ViewBuilder
    private var pillSurfaceCapture: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                onSurfaceTapped?()
            }
            .accessibilityLabel("Open chat")
            .accessibilityHint("Tap to expand the chat panel")
    }

    @ViewBuilder
    private var panelBackground: some View {
        theme.background.opacity(surfaceBackgroundOpacity)
    }

    /// Cover the home-indicator area at expansion rather than exposing a strip of the applet.
    @ViewBuilder
    private var homeIndicatorFill: some View {
        theme.background
            .opacity(bottomSafeAreaFillOpacity)
            .ignoresSafeArea(.container, edges: .bottom)
    }

    /// Clear shared SwiftUI focus and resign UIKit's responder; on iOS 26, focus alone
    /// does not reliably dismiss the keyboard.
    private func dismissKeyboard() {
        composerIsFocused.wrappedValue = false
        #if canImport(UIKit)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        #endif
    }

    /// Live speech is a display-only preview beside the current draft. Only user
    /// edits write this binding; voice additions arrive through the subscription.
    private var composerBinding: Binding<String> {
        Binding(
            get: { viewModel.displayedComposerText },
            set: { newValue in
                guard !viewModel.voiceState.isRecording else { return }
                viewModel.composerText = newValue
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        // Errors need MessageList even with no history. Read isStreaming here instead of the
        // per-token tail so deltas cannot invalidate the outer layout; the view model updates them together.
        if viewModel.items.isEmpty && !viewModel.isStreaming && viewModel.error == nil {
            ChatEmptyState()
                .overlay(alignment: .bottomTrailing) {
                    if !viewModel.suggestions.isEmpty {
                        SuggestedActions(actions: viewModel.suggestions, onSend: viewModel.send)
                            .padding(.trailing, 20)
                            .padding(.bottom, 14)
                    }
                }
                // Include blank space and suggestions but exclude the floating navigation overlay.
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
                .task { viewModel.loadSuggestionsIfNeeded(fallback: suggestedChatActions) }
        } else {
            // Conversation identity resets transcript-local scroll and expansion state.
            TranscriptObserver(
                viewModel: viewModel,
                verbosity: viewModel.verbosity,
                onRetry: viewModel.retry,
                onContentTap: dismissKeyboard,
                onCopyTapped: { text in
                    pasteboard.copy(text)
                    viewModel.confirmCopy()
                },
                onRegenerateTapped: { id in
                    viewModel.requestRegeneration(fromAssistantMessageID: id)
                }
            )
            .id(viewModel.conversationId)
        }
    }

    /// Confine tail observation here so token deltas cannot invalidate outer geometry.
    private struct TranscriptObserver: View {
        @Bindable var viewModel: ChatScreenViewModel
        let verbosity: ChatVerbosity
        let onRetry: () -> Void
        let onContentTap: () -> Void
        let onCopyTapped: (String) -> Void
        let onRegenerateTapped: (String) -> Void

        var body: some View {
            MessageList(
                items: viewModel.items,
                streamingTail: viewModel.streamingTail,
                error: viewModel.error,
                scrollRequest: viewModel.scrollRequest,
                interruptedResponse: viewModel.interruptedResponse,
                showCopyConfirmation: viewModel.showCopyConfirmation,
                verbosity: verbosity,
                onRetry: onRetry,
                onContentTap: onContentTap,
                isStreaming: viewModel.isStreaming,
                onCopyTapped: onCopyTapped,
                onRegenerateTapped: onRegenerateTapped,
                onConfirmSearch: { viewModel.confirmSearch(id: $0) },
                onSkipSearch: { viewModel.skipSearch(id: $0) }
            )
        }
    }

    private static func smoothstep(_ value: Double, from: Double, to: Double) -> Double {
        guard to > from else { return value >= to ? 1 : 0 }
        let t = min(1, max(0, (value - from) / (to - from)))
        return t * t * (3 - 2 * t)
    }
}
