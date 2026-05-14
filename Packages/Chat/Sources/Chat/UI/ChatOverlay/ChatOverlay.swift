import SwiftUI

/// The shell's chat-overlay layer. Hosts a single morphing `ChatScreen`
/// whose frame height is updated continuously while the user drags the
/// chat surface and snaps to the nearest ``ChatPresentationState`` anchor
/// on release.
///
/// The settled anchor is owned by the shell (`AppShell`) so that
/// activating a non-Chat applet can demote chat to minimized externally,
/// and selecting Chat from the sidebar can promote it back to expanded.
/// The overlay itself only mutates `settledState` in response to user
/// gestures directly on its own surface — drag-release snaps or pill
/// taps.
///
/// During a drag, the live finger-tracked height lives in
/// `dragHeight`. When `dragHeight` is non-nil, it overrides the
/// settled-anchor height so the chat tracks the finger; on release the
/// overlay computes the snap target, animates `settledState`, and
/// clears `dragHeight`.
public struct ChatOverlay: View {
    @Binding public var settledState: ChatPresentationState
    @Bindable public var viewModel: ChatScreenViewModel
    /// Forwarded to the embedded chat surface — opens Settings on the
    /// Models pane when the user picks "Manage models…" from the composer
    /// dropdown.
    public let onManageModels: () -> Void
    /// Forwarded to the chat view model's add-model-request callback —
    /// fires from the no-model error banner's CTA.
    public let onAddModelRequested: @MainActor @Sendable () -> Void

    @MainActor
    public init(
        state: Binding<ChatPresentationState>,
        viewModel: ChatScreenViewModel,
        onManageModels: @escaping () -> Void = {},
        onAddModelRequested: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self._settledState = state
        self.viewModel = viewModel
        self.onManageModels = onManageModels
        self.onAddModelRequested = onAddModelRequested
        self.frozenDragHeight = nil
    }

    /// Test-only initializer that pins the chat-surface height to
    /// `_injectedDragHeight` so snapshot suites can capture the morph
    /// at a specific in-flight progress without driving a real
    /// `DragGesture`. Production code never calls this.
    @MainActor
    init(
        state: Binding<ChatPresentationState>,
        viewModel: ChatScreenViewModel,
        _injectedDragHeight: CGFloat
    ) {
        self._settledState = state
        self.viewModel = viewModel
        self.onManageModels = {}
        self.onAddModelRequested = {}
        self.frozenDragHeight = _injectedDragHeight
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Non-nil for the duration of a drag. Driven by `ChatDragHandle`'s
    /// `onDragChanged` callback and by the pill-mode body-drag overlay
    /// inside `ChatScreen`. When non-nil, supersedes the settled-anchor
    /// height so the chat surface tracks the finger. Cleared on
    /// `onDragEnded` once the snap target has been assigned.
    @State private var dragHeight: CGFloat? = nil

    /// Snapshot-test override. When non-nil, freezes the chat-surface
    /// height at this value so baselines can be recorded mid-morph.
    private let frozenDragHeight: CGFloat?

    public var body: some View {
        GeometryReader { geo in
            content(in: geo)
        }
    }

    @ViewBuilder
    private func content(in geo: GeometryProxy) -> some View {
        let safeAreaBottom = geo.safeAreaInsets.bottom
        let containerH = geo.size.height
        let minH = ChatPresentationState.minimized.height(in: containerH, bottomSafeArea: safeAreaBottom)
        let maxH = ChatPresentationState.expanded.height(in: containerH, bottomSafeArea: safeAreaBottom)
        let settledH = settledState.height(in: containerH, bottomSafeArea: safeAreaBottom)
        // Frozen height (snapshot tests) wins over the in-flight drag
        // height, which wins over the settled anchor's height.
        let rawH = frozenDragHeight ?? dragHeight ?? settledH
        let effectiveH = min(maxH, max(minH, rawH))
        let progress = ChatPresentationState.progress(
            forHeight: effectiveH,
            in: containerH,
            bottomSafeArea: safeAreaBottom
        )

        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ChatScreen(
                viewModel: viewModel,
                progress: progress,
                onManageModels: onManageModels,
                onSurfaceTapped: { surfaceTapped() },
                onDragChanged: { translation in
                    updateDrag(translation: translation, settledH: settledH, minH: minH, maxH: maxH)
                },
                onDragEnded: { translation, predicted in
                    endDrag(
                        translation: translation,
                        predicted: predicted,
                        containerH: containerH,
                        safeAreaBottom: safeAreaBottom
                    )
                }
            )
            .frame(height: effectiveH)
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .preference(key: ChatProgressPreferenceKey.self, value: progress)
    }

    // MARK: - Drag handling

    private func updateDrag(translation: CGSize, settledH: CGFloat, minH: CGFloat, maxH: CGFloat) {
        // Downward translation (positive height) collapses; upward expands.
        // Clamp to the anchor envelope so the surface can't be dragged
        // past minimized or expanded.
        let raw = settledH - translation.height
        dragHeight = min(maxH, max(minH, raw))
    }

    private func endDrag(
        translation: CGSize,
        predicted: CGSize,
        containerH: CGFloat,
        safeAreaBottom: CGFloat
    ) {
        let velocity = predicted.height - translation.height
        let releaseHeight = dragHeight
            ?? settledState.height(in: containerH, bottomSafeArea: safeAreaBottom)
        let snap = ChatPresentationState.snapTarget(
            currentHeight: releaseHeight,
            velocity: velocity,
            containerHeight: containerH,
            bottomSafeArea: safeAreaBottom
        )
        withAnimation(ChatOverlayAnimation.transition(reduceMotion: reduceMotion)) {
            settledState = snap
            dragHeight = nil
        }
    }

    private func surfaceTapped() {
        // Tap on the pill surface — climb to semi-expanded. Mirrors the
        // prior `MinimizedChatPill.onTap`. Only fires when the chat is in
        // pill mode (the surface-tap overlay only activates at low
        // progress; see `ChatScreen.surfaceTapOverlay`).
        withAnimation(ChatOverlayAnimation.transition(reduceMotion: reduceMotion)) {
            settledState = .semiExpanded
        }
    }
}

/// Preference key the chat overlay writes its live `progress` onto so
/// `AppShell` can interpolate the applet backdrop's opacity in lockstep
/// with the chat's drag — no need for a two-way binding or a separate
/// observable.
public struct ChatProgressPreferenceKey: PreferenceKey {
    /// Treats "no overlay rendered" as fully expanded so the backdrop
    /// stays hidden behind the (absent) chat — same default the prior
    /// switch-based `backdropOpacity` produced for `.expanded`.
    public static let defaultValue: Double = 1

    public static func reduce(value: inout Double, nextValue: () -> Double) {
        value = nextValue()
    }
}
