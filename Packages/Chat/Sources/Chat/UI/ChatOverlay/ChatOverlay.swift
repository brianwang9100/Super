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

    /// External composer focus binding owned by the shell. Forwarded into
    /// `ChatScreen` so shell-driven dismissals (hamburger open, applet
    /// switch, conversation pick, backdrop tap) flip the same focus state
    /// the composer's `TextField` reads — without this, the UIKit
    /// `resignFirstResponder` dispatch hides the keyboard visually but
    /// leaves the SwiftUI focus state set, and the keyboard re-appears
    /// the next time the composer becomes interactive. `nil` falls back
    /// to `ChatScreen`'s internal `@FocusState` (snapshot tests + previews).
    private let externalComposerIsFocused: FocusState<Bool>.Binding?

    @MainActor
    public init(
        state: Binding<ChatPresentationState>,
        viewModel: ChatScreenViewModel,
        composerIsFocused: FocusState<Bool>.Binding? = nil,
        onManageModels: @escaping () -> Void = {},
        onAddModelRequested: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self._settledState = state
        self.viewModel = viewModel
        self.externalComposerIsFocused = composerIsFocused
        self.onManageModels = onManageModels
        self.onAddModelRequested = onAddModelRequested
        self.frozenDragHeight = nil
        self.frozenKeyboardAwareHeight = nil
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
        self.externalComposerIsFocused = nil
        self.onManageModels = {}
        self.onAddModelRequested = {}
        self.frozenDragHeight = _injectedDragHeight
        self.frozenKeyboardAwareHeight = nil
    }

    /// Test-only initializer that overrides the outer keyboard-aware
    /// region's height so snapshot suites can capture "keyboard is up"
    /// geometry without booting a real simulator keyboard — used to
    /// baseline the "handle stays in place" promise at the semi-
    /// expanded anchor. Production code never calls this.
    @MainActor
    init(
        state: Binding<ChatPresentationState>,
        viewModel: ChatScreenViewModel,
        _injectedKeyboardAwareHeight: CGFloat
    ) {
        self._settledState = state
        self.viewModel = viewModel
        self.externalComposerIsFocused = nil
        self.onManageModels = {}
        self.onAddModelRequested = {}
        self.frozenDragHeight = nil
        self.frozenKeyboardAwareHeight = _injectedKeyboardAwareHeight
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

    /// Live, in-flight top edge of the chat surface in keyboard-aware
    /// local space. Non-nil for the duration of a drag. Drives the
    /// resolver's `renderedHeight` directly so the visual handle tracks
    /// the finger 1:1 — independent of the top-inset cap that the
    /// settled-semi rest state applies. See ``dragHeight`` for the
    /// anchor-space companion the snap envelope reads.
    @State private var dragTopEdge: CGFloat? = nil

    /// Captured top edge at the moment the drag began. `dragTopEdge` is
    /// updated as `dragStartTopEdge + translation.height` each frame so a
    /// no-motion tap (translation = 0) yields `dragTopEdge ==
    /// startTopEdge` — i.e. exactly what was already on screen, no jump.
    @State private var dragStartTopEdge: CGFloat? = nil

    /// Snapshot-test override. When non-nil, freezes the chat-surface
    /// height at this value so baselines can be recorded mid-morph.
    private let frozenDragHeight: CGFloat?

    /// Snapshot-test override for the outer keyboard-aware region's
    /// height. When non-nil, the resolver receives this value as
    /// `Keyboard.availableHeight` and the outer frame renders at this
    /// height — emulating "keyboard is up" without a real keyboard.
    /// `nil` falls back to the live `keyboardAware.size.height` from
    /// SwiftUI.
    private let frozenKeyboardAwareHeight: CGFloat?

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
                content(
                    in: geo,
                    keyboardAwareHeight: frozenKeyboardAwareHeight ?? keyboardAware.size.height
                )
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
                bottomSafeArea: geo.safeAreaInsets.bottom,
                topSafeArea: geo.safeAreaInsets.top
            ),
            keyboard: .init(availableHeight: keyboardAwareHeight),
            interaction: .init(
                settledState: settledState,
                // Frozen height (snapshot tests) wins over the in-flight
                // drag height — both are caller-collapsed before the
                // resolver sees them.
                dragHeight: frozenDragHeight ?? dragHeight,
                // Snapshot freezes don't supply a top edge — they only
                // pin a settled-state morph, so leaving `dragTopEdge`
                // nil keeps the settled-cap branch active and matches
                // the live render at that anchor.
                dragTopEdge: dragTopEdge
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
            topSafeAreaInset: geo.safeAreaInsets.top,
            composerIsFocused: externalComposerIsFocused,
            onManageModels: onManageModels,
            onSurfaceTapped: { surfaceTapped() },
            onDragChanged: { translation in
                updateDrag(
                    translation: translation,
                    liveSettledH: metrics.settledHeight,
                    liveTopEdge: keyboardAwareHeight - metrics.renderedHeight,
                    keyboardAwareHeight: keyboardAwareHeight,
                    minH: metrics.minHeight,
                    maxH: metrics.maxHeight
                )
            },
            onDragEnded: { translation, predicted in
                endDrag(
                    translation: translation,
                    predicted: predicted,
                    containerH: geo.size.height,
                    safeAreaBottom: geo.safeAreaInsets.bottom,
                    safeAreaTop: geo.safeAreaInsets.top
                )
            }
        )
        .frame(height: metrics.renderedHeight, alignment: .bottom)
        // Use `keyboardAwareHeight` — not `geo.size.height` — so the chat surface shrinks above the keyboard; the inner GR's `.ignoresSafeArea(.keyboard)` (see body comment) blocks alternative safeAreaInset-based hoisting.
        .frame(width: geo.size.width, height: keyboardAwareHeight, alignment: .bottom)
        .preference(key: ChatProgressPreferenceKey.self, value: metrics.progress)
        .preference(key: ChatSemiProgressPreferenceKey.self, value: metrics.semiExpandedProgress)
    }

    // MARK: - Drag handling

    private func updateDrag(
        translation: CGSize,
        liveSettledH: CGFloat,
        liveTopEdge: CGFloat,
        keyboardAwareHeight: CGFloat,
        minH: CGFloat,
        maxH: CGFloat
    ) {
        // Lock the drag-start values the first time the gesture fires.
        // `liveSettledH` / `liveTopEdge` are recomputed each render and
        // could shift mid-gesture if `geo` changes (keyboard, rotation,
        // split-screen); using captured start values keeps the drag
        // stable across those.
        let startH = dragStartHeight ?? liveSettledH
        if dragStartHeight == nil { dragStartHeight = startH }
        let startTopEdge = dragStartTopEdge ?? liveTopEdge
        if dragStartTopEdge == nil { dragStartTopEdge = startTopEdge }
        // Downward translation (positive height) collapses; upward expands.
        // `dragHeight` lives in anchor space and drives `progress` /
        // snap / `crossedBelowEditorThreshold`. `dragTopEdge` lives in
        // keyboard-aware local space (y=0 at the top of the keyboard-
        // aware region) and drives the rendered geometry directly so
        // the visual handle tracks the finger 1:1 — even from the
        // capped settled-semi position.
        let rawH = startH - translation.height
        dragHeight = min(maxH, max(minH, rawH))
        let rawTopEdge = startTopEdge + translation.height
        // Top edge can't dip below 0 (top of the kb-aware region) and
        // can't sit lower than the minimized pill's top (kbAwareH - minH).
        dragTopEdge = min(max(0, rawTopEdge), max(0, keyboardAwareHeight - minH))
    }

    private func endDrag(
        translation: CGSize,
        predicted: CGSize,
        containerH: CGFloat,
        safeAreaBottom: CGFloat,
        safeAreaTop: CGFloat
    ) {
        let velocity = predicted.height - translation.height
        // Mirror the resolver's top-inset formula so the snap envelope
        // recognises the same semi anchor the user just dragged against.
        // Without this, releases in the band between the legacy ~52%
        // anchor and the new "under nav bar" anchor would snap to
        // whichever neighbour was nearest by the *old* math and visibly
        // jump on release.
        let topInset = safeAreaTop + ChatOverlayMetrics.semiExpandedChromeReserve
        let releaseHeight = dragHeight
            ?? settledState.height(in: containerH, bottomSafeArea: safeAreaBottom, topInset: topInset)
        let snap = ChatPresentationState.snapTarget(
            currentHeight: releaseHeight,
            velocity: velocity,
            containerHeight: containerH,
            bottomSafeArea: safeAreaBottom,
            topInset: topInset
        )
        withAnimation(SuperMotion.transition(reduceMotion: reduceMotion)) {
            settledState = snap
            dragHeight = nil
            dragStartHeight = nil
            dragTopEdge = nil
            dragStartTopEdge = nil
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

/// Preference key the chat overlay writes its resolved semi-expanded
/// progress onto. `AppShell.backdropOpacity` reads it as the mid-knot
/// of the dim curve so the backdrop's 0.65 opacity point lands at the
/// actual semi anchor's progress (now `containerHeight - topInset`-
/// derived) rather than the legacy 0.52 ratio.
public struct ChatSemiProgressPreferenceKey: PreferenceKey {
    /// Fallback equal to the legacy semi anchor's progress (≈0.52) so
    /// the first frame before the overlay has reported in still draws
    /// a sensible dim curve.
    public static let defaultValue: Double = 0.52

    public static func reduce(value: inout Double, nextValue: () -> Double) {
        value = nextValue()
    }
}
