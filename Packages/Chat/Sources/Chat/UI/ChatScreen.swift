import Core
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Top-level chat surface: drag handle on top, centered title, transcript or
/// empty state in the middle, composer pinned to the bottom. Owned by the
/// shell which constructs the view model with the live per-target dependency
/// graph (`SuperOSAppDependencies` / `SuperBibleAppDependencies`).
///
/// The hamburger menu lives in the shell chrome (`FixedHamburgerButton` in
/// `App/Shell/`), not in this surface. The drag handle is visually present
/// in M1 but the snap-to-presentation-state gesture wires up in M3.
///
/// `progress` (0 = pill, 1 = expanded screen) drives every visual that
/// differs between the three presentation states — header visibility,
/// transcript opacity, panel rounded-rect surround, shadow, and the
/// composer's own pill/full morph. The chat overlay computes `progress`
/// from the live chat-surface height and feeds it down so the entire
/// surface resizes continuously under a drag instead of swapping
/// between three discrete view hierarchies.
public struct ChatScreen: View {
    @Bindable public var viewModel: ChatScreenViewModel
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

    /// `0` renders the surface as the minimized pill (only the morphing
    /// `ChatComposer` shows, panel surround hidden, transcript faded);
    /// `1` renders the full expanded screen (header + transcript +
    /// composer, no panel surround, chat fills the viewport). Driven
    /// from `ChatOverlay` based on the live drag height.
    public let progress: Double

    /// Fires when the user taps the chat surface in pill mode. Wired by
    /// `ChatOverlay` to expand to ``ChatPresentationState/semiExpanded`` —
    /// mirrors the prior `MinimizedChatPill.onTap`.
    public let onSurfaceTapped: (() -> Void)?

    /// Forwarded to the embedded `ChatDragHandle` *and* to the pill-mode
    /// body-drag overlay. Fires on every drag-changed tick with the live
    /// translation so the overlay can update its chat-surface height in
    /// real time.
    public let onDragChanged: ((_ translation: CGSize) -> Void)?

    /// Forwarded to the embedded `ChatDragHandle` *and* to the pill-mode
    /// body-drag overlay. Fires on drag-end with the gesture's translation
    /// and SwiftUI's predicted-end-translation (a velocity proxy). Wired by
    /// `ChatOverlay` to snap to the nearest presentation state on release.
    public let onDragEnded: ((_ translation: CGSize, _ predictedEndTranslation: CGSize) -> Void)?

    /// Composer focus binding owned by the shell. When non-nil, the
    /// composer's `TextField` binds to this — letting the shell clear
    /// focus on any "user moved away from the composer" transition
    /// (hamburger open, applet switch, conversation pick, backdrop tap,
    /// drag-collapse past the editor-interactive threshold). When `nil`,
    /// `ChatScreen` falls back to its own `@FocusState` so tests and
    /// previews that don't care about cross-view focus management can
    /// construct it without threading a binding through.
    private let externalComposerIsFocused: FocusState<Bool>.Binding?

    @MainActor
    public init(
        viewModel: ChatScreenViewModel,
        progress: Double = 1,
        composerIsFocused: FocusState<Bool>.Binding? = nil,
        onManageModels: @escaping () -> Void = {},
        onAddModelRequested: @escaping @MainActor @Sendable () -> Void = {},
        onSurfaceTapped: (() -> Void)? = nil,
        onDragChanged: ((_ translation: CGSize) -> Void)? = nil,
        onDragEnded: ((_ translation: CGSize, _ predictedEndTranslation: CGSize) -> Void)? = nil,
        clock: any Clock = SystemClock(),
        calendar: Calendar = .current
    ) {
        self.viewModel = viewModel
        self.progress = progress
        self.externalComposerIsFocused = composerIsFocused
        self.onManageModels = onManageModels
        self.onSurfaceTapped = onSurfaceTapped
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
        self.clock = clock
        self.calendar = calendar
        viewModel.onAddModelRequested = onAddModelRequested
    }

    @Environment(\.superTheme) private var theme
    /// System pasteboard client. Owned at this level so the Copy
    /// callback for each ``AssistantMessage`` writes the text *and*
    /// flips the view-model's transient "Copied!" pill in the same
    /// gesture handler.
    @Environment(\.pasteboardClient) private var pasteboard
    /// Fallback focus state used only when no external binding is passed in
    /// (snapshot tests, previews). The composer reads
    /// ``composerIsFocused`` which prefers the external binding when
    /// present so shell-driven dismissals stay durable across re-expand.
    @FocusState private var internalComposerIsFocused: Bool

    /// Effective composer focus binding — external when the shell wired
    /// one in, otherwise the internal `@FocusState` fallback above.
    private var composerIsFocused: FocusState<Bool>.Binding {
        externalComposerIsFocused ?? $internalComposerIsFocused
    }

    // MARK: - Progress-driven interpolations

    /// Header (title row) is hidden in pill and semi-expanded, fading
    /// in as the surface climbs toward fully expanded. Driven by
    /// `headerProgress` so opacity, scale, and the slot height stay in
    /// lockstep — without this the header used to pop in at a hard
    /// `progress > 0.7` threshold, which felt jarring during the morph.
    private var headerProgress: Double {
        Self.smoothstep(progress, from: 0.6, to: 0.95)
    }

    /// Approximate intrinsic height of `ChatHeader` at default Dynamic
    /// Type. Used as the upper bound for the header's collapsing slot
    /// so the row reserves zero vertical space when fully hidden and
    /// its natural height when fully visible. Reasonable Dynamic Type
    /// growth (~XXL) still fits inside the expanded chat-surface's
    /// remaining slack; if it ever doesn't, swap this for a
    /// PreferenceKey measurement.
    private static let headerIntrinsicHeight: CGFloat = 38

    /// Transcript / empty-state opacity. Hidden in pill mode (no room),
    /// fades in around the semi-expanded transition so a glance-and-reply
    /// surface shows messages.
    private var contentOpacity: Double {
        Self.smoothstep(progress, from: 0.15, to: 0.45)
    }


    /// Pill-mode tap-to-expand overlay. Only mounted in pill mode so it
    /// doesn't swallow taps on the live composer's text field at higher
    /// progress. `<= 0.15` (rather than `< 0.15`) closes the off-by-one
    /// against ``ChatComposer/editorInteractive``'s `> 0.15` gate so a
    /// tap exactly on the band edge always lands on a live target —
    /// the pill overlay at the boundary, the editor immediately past
    /// it. The drag affordance is the always-visible `ChatDragHandle`;
    /// this overlay no longer drives drags — that removes the prior
    /// "gesture dies when overlay un-mounts at `progress = 0.15`" stall
    /// and the parallel "drag handle un-mounts at `progress = 0.05`"
    /// stall.
    private var pillSurfaceCaptureActive: Bool {
        progress <= ChatPresentationState.editorInteractiveThreshold
    }

    /// Surround opacity: rounded-rect panel background + stroke + shadow
    /// that make the chat read as a floating panel in semi-expanded mode.
    /// Hidden in pill mode (composer's own capsule shadow takes over) and
    /// in fully-expanded mode (chat fills the screen, no floating
    /// effect).
    private var panelSurroundOpacity: Double {
        let fadeIn = Self.smoothstep(progress, from: 0, to: 0.1)
        let fadeOut = 1 - Self.smoothstep(progress, from: 0.9, to: 1.0)
        return fadeIn * fadeOut
    }

    /// Chat-surface background opacity. Fades in alongside the panel
    /// surround so the applet shows through in pill mode and the
    /// background is solid by semi-expanded. Stays opaque through full
    /// expansion — the home-indicator fill behind handles the unsafe
    /// area at progress = 1.
    private var surfaceBackgroundOpacity: Double {
        Self.smoothstep(progress, from: 0, to: 0.1)
    }

    /// Rounded-rect surround corner radius. 24pt at pill (matches the
    /// prior `MinimizedChatPill` radius) interpolating to 0 at full
    /// expansion. The surround itself is invisible at both extremes so
    /// only the mid-range values are visually load-bearing.
    private var panelCornerRadius: CGFloat {
        Self.lerp(progress, 24, 0)
    }

    /// Fade in the home-indicator background extension only as the chat
    /// fills the screen, so pill / semi modes leave the unsafe area
    /// showing the applet (their visual identity is "floating panel above
    /// the applet").
    private var bottomSafeAreaFillOpacity: Double {
        Self.smoothstep(progress, from: 0.95, to: 1.0)
    }

    /// Title shown in the Regenerate confirmation dialog. Switches between
    /// the single-message form and the multi-message form so the user
    /// reads the right severity for the targeted point.
    private var regenerationDialogTitle: String {
        viewModel.pendingRegenerationDeleteCount <= 1
            ? "Regenerate this response?"
            : "Regenerate from here?"
    }

    /// Subtitle below the title. Naming the explicit count of later
    /// messages that will be deleted is the load-bearing part — it's
    /// what makes the destructive nature visible at the targeted point.
    private var regenerationDialogMessage: String {
        let count = viewModel.pendingRegenerationDeleteCount
        if count <= 1 {
            return "This response will be replaced."
        }
        let later = count - 1
        let plural = later == 1 ? "message" : "messages"
        return "This response and \(later) later \(plural) will be deleted."
    }

    /// Two-way binding from `pendingRegenerationTargetID != nil` to the
    /// dialog's `isPresented`. SwiftUI calls the setter with `false`
    /// when the user taps Cancel or hits the dim — route that through
    /// `cancelRegeneration()` so the pending state clears cleanly.
    /// Setter ignores `true` writes — the only path that opens the
    /// dialog is `requestRegeneration(fromAssistantMessageID:)` from a
    /// button tap.
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
            // Always visible — the drag handle is the unified drag
            // affordance for every settled state. In minimized mode it
            // sits directly above the composer pill; in semi and
            // expanded it sits at the top of the panel. Keeping it
            // mounted at every progress also means a drag started in
            // one state can carry the chat to any other without the
            // gesture's host view ever leaving the tree mid-flight.
            ChatDragHandle(
                onDragChanged: onDragChanged,
                onDragEnded: onDragEnded
            )
            ChatHeader(title: viewModel.headerTitle)
                // Scale runs the full 0→1 range so the title's
                // translucent box collapses to size 0,0 at the bottom
                // of the animation rather than snapping in at 70%
                // size. The frame height collapses with the same
                // `headerProgress` so the row reserves zero space when
                // the box is at 0,0.
                .scaleEffect(headerProgress, anchor: .top)
                .opacity(headerProgress)
                .frame(height: CGFloat(headerProgress) * Self.headerIntrinsicHeight, alignment: .top)
                .clipped()
            content
                // `minHeight: 0` overrides the inner view's intrinsic
                // floor (`ChatEmptyState`'s ~90pt icon+greeting,
                // `MessageList`'s row stack) so the content slot takes
                // *exactly* the leftover space between handle and
                // composer at every progress. Without this override
                // the VStack centered its 92.5pt of intrinsic content
                // inside the larger frame mid-drag — the composer
                // visibly drifted up with the handle and then
                // "blipped" back to the bottom once a discrete
                // threshold flipped the slot to flexible. Now the
                // composer stays anchored at the bottom continuously
                // and the surface grows upward from it.
                .frame(minHeight: 0, maxHeight: .infinity)
                .opacity(contentOpacity)
                .overlay(alignment: .bottom) {
                    // Transient "Copied!" pill floats at the bottom edge
                    // of the transcript area, which puts it directly
                    // above the composer at every progress level.
                    // Attached *before* `.clipped()` so the slide-in's
                    // off-screen start is clipped away — the pill
                    // visually emerges from behind the composer's top
                    // edge instead of sliding across it.
                    if viewModel.showCopyConfirmation {
                        CopyConfirmationPill()
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                            .allowsHitTesting(false)
                    }
                }
                .clipped()
                .animation(.easeInOut(duration: 0.18), value: viewModel.showCopyConfirmation)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded { dismissKeyboard() }
                )
            composer
        }
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
        .overlay {
            // Stroke border around the panel surround. Fades in/out with
            // the rest of the panel so it doesn't ring the screen at full
            // expansion.
            RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                .strokeBorder(theme.borderFaint, lineWidth: 1)
                .opacity(panelSurroundOpacity)
        }
        .shadow(color: Color.black.opacity(0.18 * panelSurroundOpacity), radius: 12, x: 0, y: 12)
        .shadow(color: Color.black.opacity(0.12 * panelSurroundOpacity), radius: 30, x: 0, y: 30)
        .background(homeIndicatorFill)
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
        // Bind the load to the conversation id so swapping the view
        // model when the user picks a different chat from the sidebar
        // re-fires `load()` against the new transcript. A bare `.task`
        // (no id) only fires on first appear — switching chats would
        // otherwise leave the new view model unloaded and the surface
        // stuck on the empty state.
        .task(id: viewModel.conversationId) {
            // Drain any verse pills the shell inbox buffered before this
            // composer mounted, then load the transcript.
            viewModel.adoptPendingReferences()
            await viewModel.load()
        }
        .onChange(of: viewModel.voice.state) { _, newState in
            viewModel.handleVoiceStateChange(newState)
        }
        // When the surface collapses past the editor-interactive threshold
        // the composer's `TextField` becomes `.disabled`. Disabling a
        // focused field does not clear `@FocusState`, so without this the
        // keyboard would stay wedged half-open over a dead field — and
        // re-expanding would resurrect it because focus was never released.
        // Dismissing on the downward crossing tears the keyboard down
        // deterministically and keeps it down until the user taps the
        // field again. `crossedBelowEditorThreshold` fires only when
        // `progress` is decreasing, so an expand never trips it.
        .onChange(of: progress) { oldValue, newValue in
            if ChatPresentationState.crossedBelowEditorThreshold(from: oldValue, to: newValue) {
                dismissKeyboard()
            }
        }
        // A verse added from Bible while this screen is already on-screen
        // grows the inbox; adopt it without waiting for a remount.
        .onChange(of: viewModel.inboxPendingCount) { _, _ in
            viewModel.adoptPendingReferences()
        }
    }

    /// Composer pinned to the bottom of the surface. Stacks a pill-mode
    /// tap-or-drag capture overlay on top at low progress so the user
    /// can grow the chat by dragging anywhere on the pill (or expand to
    /// semi by tapping it). At higher progress the overlay is gone and
    /// the underlying composer's text editor + footer become
    /// interactive.
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
            isRecording: viewModel.voice.state == .listening,
            isMicAvailable: viewModel.voice.state != .unavailable,
            onStopRecording: viewModel.handleStopRecording,
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

    /// Transparent overlay that catches a tap on the pill body in
    /// minimized mode → expand to semi via `onSurfaceTapped`. Only
    /// mounted at low progress so the live composer's text field stays
    /// tappable at higher progress. Drag is handled by the always-
    /// visible `ChatDragHandle`, so this overlay no longer carries a
    /// `DragGesture` of its own.
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

    /// Panel surround background: rounded-rect raised fill that sits
    /// behind the chat content and fades in/out with `panelSurroundOpacity`.
    /// In pill mode the composer's own capsule does the lifted-surface
    /// duty so this layer hides; in expanded mode the chat-surface base
    /// background handles the solid fill so this layer also hides.
    @ViewBuilder
    private var panelBackground: some View {
        ZStack {
            // Chat-surface base background — fades in alongside the
            // panel so pill mode lets the applet through, fully opaque
            // by mid-drag onward. Doesn't extend past the safe area;
            // see `homeIndicatorFill` for the at-full-expansion unsafe
            // area cover.
            theme.background.opacity(surfaceBackgroundOpacity)
            // Panel surround — visible only when the chat reads as a
            // floating panel. The corner radius is shared with the
            // outer clipShape so the two layers stay aligned during
            // the morph.
            RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                .fill(theme.backgroundRaised.opacity(0.95))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
                .opacity(panelSurroundOpacity)
        }
    }

    /// Bottom-anchored extension that paints over the home-indicator's
    /// unsafe area only when the chat is fully (or nearly fully)
    /// expanded. Applied as an outer background so it sits behind the
    /// chat-surface and behind `panelBackground`'s clip — without it the
    /// expanded chat would leave a 34pt strip of applet visible under
    /// the home indicator.
    @ViewBuilder
    private var homeIndicatorFill: some View {
        theme.background
            .opacity(bottomSafeAreaFillOpacity)
            .ignoresSafeArea(.container, edges: .bottom)
    }

    /// Dismiss the on-screen keyboard *and* clear the SwiftUI `@FocusState`
    /// so the composer's focused-border styling unsets. Writes through
    /// ``composerIsFocused`` so the clear lands on whichever binding owns
    /// focus — the shell's when wired in (production), the internal
    /// fallback otherwise (tests). The UIKit `resignFirstResponder`
    /// dispatch is the load-bearing piece — on iOS 26.x, flipping
    /// `@FocusState` alone doesn't always tear down the keyboard, so the
    /// UIKit call is what reliably hides it. The `#if canImport(UIKit)`
    /// branch compiles out on macOS where there's no on-screen keyboard;
    /// the focus clear still runs so the border styling stays consistent
    /// across platforms.
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
        // Render `MessageList` (not the empty-state greeting) whenever
        // an error banner needs a surface, even in a brand-new chat
        // with zero items. `MessageList` owns the `ErrorBanner`, so an
        // active error in the empty branch would otherwise have nowhere
        // to render and the user would still see a silent failure.
        //
        // Reads `viewModel.isStreaming` (not `viewModel.streamingTail`)
        // for the empty-state guard so per-token deltas don't invalidate
        // `ChatScreen.body`. The view-model invariant we rely on:
        // `streamingTail != nil ⇔ isStreaming == true` from any observer's
        // perspective. The view model writes both flags inside the same
        // synchronous `@MainActor` turn whenever it enters or leaves a
        // streaming window (`startStreaming`, `attachToLiveTurnIfAny`,
        // and the `consume` cleanup all do), so SwiftUI's body evaluation
        // cannot observe one without the other — the write order between
        // them is therefore not load-bearing. `_setSnapshotState`
        // preconditions the pair so test fixtures can't violate it
        // either.
        if viewModel.items.isEmpty && !viewModel.isStreaming && viewModel.error == nil {
            ChatEmptyState(clock: clock, calendar: calendar)
        } else {
            // The streaming tail observation is confined to
            // `TranscriptObserver` so token-delta writes only invalidate
            // the transcript leaf — not `ChatScreen.body` (which would
            // re-run every interpolation against `progress`) nor the
            // overlay's geometry math (which derives from `metrics`,
            // not the tail). The `.id(conversationId)` re-mounts the
            // observer + its child `MessageList` per conversation so
            // SwiftUI discards the prior `@State` (scroll offset etc.).
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

    /// Owns the `viewModel.streamingTail` read so streaming token deltas
    /// invalidate only this view (and its `MessageList` child), not
    /// `ChatScreen.body` or the overlay's geometry. The view-body
    /// dependencies are the streaming tail, the persisted-items list,
    /// and the error banner — i.e. exactly the inputs `MessageList`
    /// already consumes — so this observer is effectively a thin
    /// "transcript projection" of the view model.
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
                verbosity: verbosity,
                onRetry: onRetry,
                onContentTap: onContentTap,
                isStreaming: viewModel.isStreaming,
                onCopyTapped: onCopyTapped,
                onRegenerateTapped: onRegenerateTapped
            )
        }
    }

    // MARK: - Math helpers

    /// Linear interpolation between `a` and `b` by `t` (clamped to [0, 1]).
    private static func lerp(_ t: Double, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, t))
        return a + (b - a) * CGFloat(clamped)
    }

    /// Hermite (3t² − 2t³) smoothstep mapping `value` from `[from, to]`
    /// onto `[0, 1]`. Outside that band the result clamps. Used to fade
    /// chat-surface accents around progress milestones without the
    /// kink a linear ramp would leave at the band endpoints.
    private static func smoothstep(_ value: Double, from: Double, to: Double) -> Double {
        guard to > from else { return value >= to ? 1 : 0 }
        let t = min(1, max(0, (value - from) / (to - from)))
        return t * t * (3 - 2 * t)
    }
}
