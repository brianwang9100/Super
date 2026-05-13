import Core
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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
    /// Clock used by the empty-state greeting. Production wires
    /// `SystemClock()`; snapshot tests pass a `FixedClock` so the
    /// baselines don't drift across the morning/afternoon/evening
    /// hour buckets at recording time.
    private let clock: any Clock
    /// Calendar used by the empty-state greeting's hour-of-day lookup.
    /// Production wires `.current` (system timezone); snapshot tests
    /// pin it to UTC so the hour bucket is identical on developer
    /// machines (typically America/Los_Angeles) and on CI runners
    /// (typically UTC) — otherwise the same `FixedClock` instant lands
    /// in different hour buckets and baselines mismatch.
    private let calendar: Calendar

    public init(
        viewModel: ChatScreenViewModel,
        onMenuTap: @escaping () -> Void = {},
        onManageModels: @escaping () -> Void = {},
        clock: any Clock = SystemClock(),
        calendar: Calendar = .current
    ) {
        self.viewModel = viewModel
        self.onMenuTap = onMenuTap
        self.onManageModels = onManageModels
        self.clock = clock
        self.calendar = calendar
    }

    @Environment(\.superTheme) private var theme
    /// Focus state for the composer's `TextField`. Lifted out of
    /// `ChatComposer` so taps on the transcript, taps on the hamburger,
    /// and scroll drags can dismiss the keyboard by clearing this value.
    @FocusState private var composerIsFocused: Bool

    public var body: some View {
        VStack(spacing: 0) {
            ChatHeader(title: viewModel.headerTitle, onMenuTap: handleMenuTap)
            content
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                // `simultaneousGesture` (not `onTapGesture`) so the tap-to-dismiss
                // path coexists with any tappable content the empty state or
                // message list may gain. The populated branch also dismisses
                // from inside `MessageList`; both firing is harmless because
                // `dismissKeyboard()` is idempotent.
                .simultaneousGesture(
                    TapGesture().onEnded { dismissKeyboard() }
                )
            ChatComposer(
                text: composerBinding,
                isFocused: $composerIsFocused,
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
                isRecording: viewModel.voice.state == .listening,
                isMicAvailable: viewModel.voice.state != .unavailable,
                onStopRecording: viewModel.handleStopRecording
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
        .onChange(of: viewModel.voice.state) { _, newState in
            viewModel.handleVoiceStateChange(newState)
        }
    }

    /// Dismiss the on-screen keyboard *and* clear the SwiftUI `@FocusState`
    /// so the composer's focused-border styling unsets. The UIKit
    /// `resignFirstResponder` dispatch is the load-bearing piece — on
    /// iOS 26.x, setting `@FocusState` from a sibling view doesn't always
    /// tear down the keyboard, so the UIKit call is what reliably hides
    /// it. The `#if canImport(UIKit)` branch compiles out on macOS where
    /// there's no on-screen keyboard; the `@FocusState` clear still runs
    /// so the border styling stays consistent across platforms.
    private func dismissKeyboard() {
        composerIsFocused = false
        #if canImport(UIKit)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        #endif
    }

    /// Dismiss the keyboard before opening the sidebar so the drawer
    /// doesn't slide in over a still-visible keyboard.
    private func handleMenuTap() {
        dismissKeyboard()
        onMenuTap()
    }

    /// Composer binding that splices the live partial transcript onto
    /// the user-typed prefix while recording, and bypasses to the plain
    /// `composerText` everywhere else. Lives in the view (not the view
    /// model) so the binding logic stays adjacent to the `TextField`
    /// it feeds.
    private var composerBinding: Binding<String> {
        Binding(
            get: {
                if viewModel.voice.state == .listening {
                    let partial = viewModel.voice.partialTranscript
                    let prefix = viewModel.committedComposerText
                    if partial.isEmpty {
                        return prefix
                    } else if prefix.isEmpty {
                        return partial
                    } else {
                        return "\(prefix) \(partial)"
                    }
                }
                return viewModel.composerText
            },
            set: { newValue in
                // Defense in depth: the `TextField` is `.disabled` while
                // recording so writes shouldn't reach this set: arm,
                // but a future caller forgetting to disable would let a
                // mid-recording write replace the user's prefix while
                // partials keep streaming. Guard explicitly.
                guard viewModel.voice.state != .listening else { return }
                viewModel.composerText = newValue
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.items.isEmpty && viewModel.streamingTail == nil {
            ChatEmptyState(clock: clock, calendar: calendar)
        } else {
            MessageList(
                items: viewModel.items,
                streamingTail: viewModel.streamingTail,
                error: viewModel.error,
                verbosity: viewModel.verbosity,
                onRetry: viewModel.retry,
                onContentTap: dismissKeyboard
            )
        }
    }
}
