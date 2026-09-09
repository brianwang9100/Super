import Core
import SwiftUI

/// The shell owns the settled anchor; live drag geometry overrides it until release.
public struct ChatOverlay: View {
    @Binding public var settledState: ChatPresentationState
    @Bindable public var viewModel: ChatScreenViewModel
    public let onManageModels: () -> Void
    public let onAddModelRequested: @MainActor @Sendable () -> Void

    /// Share SwiftUI focus with the shell: resignFirstResponder alone leaves focus set
    /// and can reopen the keyboard when the composer becomes interactive.
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

    /// Snapshot seam for an in-flight morph without a real drag.
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

    /// Snapshot seam for keyboard geometry without a live keyboard.
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

    @State private var dragHeight: CGFloat? = nil

    /// Capture once so keyboard and container changes cannot shift the drag origin.
    @State private var dragStartHeight: CGFloat? = nil

    /// Keyboard-aware top edge drives rendered geometry independently of the settled inset cap.
    @State private var dragTopEdge: CGFloat? = nil

    @State private var dragStartTopEdge: CGFloat? = nil

    /// Tell the body recognizer to drop latched state after settles or keyboard changes.
    @State private var dragResetToken = 0

    private let frozenDragHeight: CGFloat?

    private let frozenKeyboardAwareHeight: CGFloat?

    public var body: some View {
        // Keep anchor math on keyboard-free geometry; use the outer reader only to cap
        // rendered height. Otherwise keyboard appearance collapses the anchor envelope mid-spring.
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
        let metrics = ChatOverlayMetrics(
            device: .init(
                containerHeight: geo.size.height,
                bottomSafeArea: geo.safeAreaInsets.bottom,
                topSafeArea: geo.safeAreaInsets.top
            ),
            keyboard: .init(availableHeight: keyboardAwareHeight),
            interaction: .init(
                settledState: settledState,
                dragHeight: frozenDragHeight ?? dragHeight,
                dragTopEdge: dragTopEdge
            )
        )

        // Bottom alignment prevents morph arithmetic from moving the composer off-screen.
        // The inner frame clips excess transcript height from the top.
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
            },
            dragResetToken: dragResetToken
        )
        // Clear latches for shell transitions and keyboard changes as well as drag releases.
        .onChange(of: settledState) { resetDragState() }
        .onChange(of: keyboardAwareHeight < geo.size.height - 1) { resetDragState() }
        .frame(height: metrics.renderedHeight, alignment: .bottom)
        .frame(width: geo.size.width, height: keyboardAwareHeight, alignment: .bottom)
        // Animate inset changes because keyboard-free geometry bypasses layout avoidance.
        // Keying on the inset lets rotation and resize remain immediate.
        .animation(reduceMotion ? nil : SuperMotion.keyboardGlide, value: geo.size.height - keyboardAwareHeight)
        .preference(key: ChatProgressPreferenceKey.self, value: metrics.progress)
        .preference(key: ChatSemiProgressPreferenceKey.self, value: metrics.semiExpandedProgress)
    }

    private func updateDrag(
        translation: CGSize,
        liveSettledH: CGFloat,
        liveTopEdge: CGFloat,
        keyboardAwareHeight: CGFloat,
        minH: CGFloat,
        maxH: CGFloat
    ) {
        let startH = dragStartHeight ?? liveSettledH
        if dragStartHeight == nil { dragStartHeight = startH }
        let startTopEdge = dragStartTopEdge ?? liveTopEdge
        if dragStartTopEdge == nil { dragStartTopEdge = startTopEdge }
        // Anchor-space height drives progress and snapping; keyboard-aware top edge drives rendering.
        let rawH = startH - translation.height
        dragHeight = min(maxH, max(minH, rawH))
        let rawTopEdge = startTopEdge + translation.height
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
        // Match the resolver's inset so snapping uses the same semi anchor the user dragged against.
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

    private func resetDragState() {
        dragHeight = nil
        dragStartHeight = nil
        dragTopEdge = nil
        dragStartTopEdge = nil
        dragResetToken &+= 1
    }

    private func surfaceTapped() {
        withAnimation(SuperMotion.transition(reduceMotion: reduceMotion)) {
            settledState = .semiExpanded
        }
    }
}

/// Reports live overlay progress to the shell's backdrop.
public struct ChatProgressPreferenceKey: PreferenceKey {
    /// Keep the backdrop hidden when no overlay reports a value.
    public static let defaultValue: Double = 1

    public static func reduce(value: inout Double, nextValue: () -> Double) {
        // Requires one overlay writer per scene.
        value = nextValue()
    }
}

/// Reports the semi anchor's actual progress for the midpoint of the backdrop dim curve.
public struct ChatSemiProgressPreferenceKey: PreferenceKey {
    /// Fallback until the overlay reports its first geometry.
    public static let defaultValue: Double = 0.52

    public static func reduce(value: inout Double, nextValue: () -> Double) {
        value = nextValue()
    }
}
