import Core
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

    /// Captured chat-surface height at the moment the drag began.
    /// `DragGesture.translation` is cumulative from the gesture's start,
    /// so the drag's effective height is `dragStartHeight - translation`.
    /// Caching the start height in `@State` (rather than re-deriving from
    /// `settledState.height(in: geo, ...)` on every render) keeps the
    /// drag immune to geometry changes mid-gesture — keyboard appearing,
    /// device rotation, split-screen resize — which would otherwise
    /// recompute a different `settledH` and produce a visible snap.
    @State private var dragStartHeight: CGFloat? = nil

    /// Snapshot-test override. When non-nil, freezes the chat-surface
    /// height at this value so baselines can be recorded mid-morph.
    private let frozenDragHeight: CGFloat?

    public var body: some View {
        // Two nested readers separate the keyboard from the device
        // geometry. The *outer* reader is keyboard-aware — when a field is
        // focused its height shrinks by the keyboard's height. The *inner*
        // reader carries `.ignoresSafeArea(.keyboard)`, so its `geo` is
        // pure device geometry (size + insets) that never moves when the
        // keyboard toggles. The anchor math (`minH`/`maxH`/`progress`/…)
        // all runs off the inner `geo`; the keyboard-aware height only
        // caps the surface's *rendered* height so it stays above the
        // keyboard (see `content(in:)`).
        //
        // Driving the anchor math off a keyboard-aware height instead
        // collapses the whole anchor envelope (`maxH`, `semiExpanded`
        // height, `progress`) the instant the keyboard appears — which,
        // mid-transition, fights the snap spring and leaves the surface
        // translated off the bottom of the screen.
        GeometryReader { keyboardAware in
            GeometryReader { geo in
                content(in: geo, keyboardAwareHeight: keyboardAware.size.height)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
    }

    @ViewBuilder
    private func content(
        in geo: GeometryProxy,
        keyboardAwareHeight: CGFloat
    ) -> some View {
        // The resolver consolidates every anchor/height/progress value
        // into one typed value — `metrics` — so the view layer is a
        // projection rather than an inline computation. The three input
        // categories are separated: `device` (keyboard-free, from `geo`),
        // `keyboard` (the only seam the software keyboard enters at),
        // `interaction` (the settled anchor and any live drag/freeze
        // override). See `ChatOverlayMetrics` for the input/output contract.
        let metrics = ChatOverlayMetrics(
            device: .init(
                containerHeight: geo.size.height,
                bottomSafeArea: geo.safeAreaInsets.bottom
            ),
            keyboard: .init(availableHeight: keyboardAwareHeight),
            interaction: .init(
                settledState: settledState,
                // Frozen height (snapshot tests) wins over the in-flight
                // drag height — both are caller-collapsed before the
                // resolver sees them.
                dragHeight: frozenDragHeight ?? dragHeight
            )
        )

        // The chat surface's position is *declared* — `alignment: .bottom`
        // on the outer frame pins ChatScreen to the bottom edge of the
        // keyboard-aware region, no `Spacer` slack arithmetic. The bottom
        // pin is a layout fact, not a side effect of `containerH - effectiveH`
        // happening to land at zero. The motivating regression (PR #65,
        // user-reported as: "submit a message, then minimize/expand while
        // it streams, and the whole composer slides off the bottom of the
        // screen"): when the slack expression drifted mid-stream, the
        // surface silently translated off-screen. With a declared anchor,
        // that failure mode is structurally impossible — there is no
        // arithmetic for the position.
        //
        // The inner frame is `renderedHeight` tall with `alignment: .bottom`
        // so ChatScreen's intrinsic content (handle + composer capsule)
        // clips from the top (transcript) when the rendered height dips
        // below the intrinsic minimum, rather than spilling the composer
        // past the bottom edge.
        ChatScreen(
            viewModel: viewModel,
            progress: metrics.progress,
            onManageModels: onManageModels,
            onSurfaceTapped: { surfaceTapped() },
            onDragChanged: { translation in
                updateDrag(
                    translation: translation,
                    liveSettledH: metrics.settledHeight,
                    minH: metrics.minHeight,
                    maxH: metrics.maxHeight
                )
            },
            onDragEnded: { translation, predicted in
                endDrag(
                    translation: translation,
                    predicted: predicted,
                    containerH: geo.size.height,
                    safeAreaBottom: geo.safeAreaInsets.bottom
                )
            }
        )
        .frame(height: metrics.renderedHeight, alignment: .bottom)
        .frame(width: geo.size.width, height: keyboardAwareHeight, alignment: .bottom)
        .preference(key: ChatProgressPreferenceKey.self, value: metrics.progress)
    }

    // MARK: - Drag handling

    private func updateDrag(
        translation: CGSize,
        liveSettledH: CGFloat,
        minH: CGFloat,
        maxH: CGFloat
    ) {
        // Lock the drag-start height the first time the gesture fires.
        // `liveSettledH` is recomputed each render and could shift mid-
        // gesture if `geo` changes (keyboard, rotation, split-screen);
        // using the captured value keeps the drag stable across those.
        let startH = dragStartHeight ?? liveSettledH
        if dragStartHeight == nil { dragStartHeight = startH }
        // Downward translation (positive height) collapses; upward expands.
        // Clamp to the anchor envelope so the surface can't be dragged
        // past minimized or expanded.
        let raw = startH - translation.height
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
        withAnimation(SuperMotion.transition(reduceMotion: reduceMotion)) {
            settledState = snap
            dragHeight = nil
            dragStartHeight = nil
        }
    }

    private func surfaceTapped() {
        // Tap on the pill surface — climb to semi-expanded. Mirrors the
        // prior `MinimizedChatPill.onTap`. Only fires when the chat is in
        // pill mode (the surface-tap overlay only activates at low
        // progress; see `ChatScreen.surfaceTapOverlay`).
        withAnimation(SuperMotion.transition(reduceMotion: reduceMotion)) {
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
        // Single-writer assumption: only one `ChatOverlay` per scene
        // writes this key, so "last child wins" is fine. If a future
        // refactor mounts a second overlay this reduce needs a
        // deliberate merge strategy — without it the shell would
        // silently read whichever overlay SwiftUI happens to process
        // last.
        value = nextValue()
    }
}
