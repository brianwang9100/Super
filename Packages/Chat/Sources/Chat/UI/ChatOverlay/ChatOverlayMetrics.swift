import SwiftUI

/// Resolved chat-overlay layout — every height/progress value the SwiftUI
/// views read in a single pass-through render.
///
/// The resolver takes three explicitly separated input categories so each
/// enters the layout at one well-defined seam, instead of three different
/// sources funnelling through one `GeometryProxy` and collapsing into one
/// number (which was how the streaming/keyboard layout regression in PR #65
/// became possible).
///
/// Inputs:
/// - ``Device`` — keyboard-free window size + home-indicator inset (what
///   the anchor envelope and `progress` are computed against). Sourced from
///   the inner `.ignoresSafeArea(.keyboard)` `GeometryReader`.
/// - ``Keyboard`` — the space above the software keyboard. The *only*
///   input the keyboard enters; caps ``renderedHeight`` so the
///   bottom-pinned composer can never be pushed off-screen.
/// - ``Interaction`` — the settled anchor, plus an optional live drag
///   height (drag or snapshot-test freeze, already collapsed by the caller).
///
/// Outputs are derived once on init; the views read fields rather than
/// recomputing inline. Each input category is independently testable, and
/// the keyboard input is provably orthogonal to the anchor math — anchor
/// heights and `progress` only depend on ``Device`` + ``Interaction``.
public struct ChatOverlayMetrics: Sendable, Equatable {
    /// Keyboard-free device geometry the anchor envelope is resolved against.
    public struct Device: Sendable, Equatable {
        /// Full container height with the keyboard ignored — i.e. the
        /// scene height not counting any software-keyboard intrusion.
        public let containerHeight: CGFloat
        /// Bottom home-indicator inset (also keyboard-free), so the
        /// minimized pill rests *above* the indicator rather than behind it.
        public let bottomSafeArea: CGFloat
        /// Top safe-area inset (status bar / Dynamic Island). Combined
        /// with ``ChatOverlayMetrics/semiExpandedChromeReserve`` to form
        /// the top inset the semi-expanded anchor reserves so the drag
        /// handle lands flush under the backdrop applet's nav bar
        /// instead of mid-screen.
        public let topSafeArea: CGFloat

        public init(containerHeight: CGFloat, bottomSafeArea: CGFloat, topSafeArea: CGFloat = 0) {
            self.containerHeight = containerHeight
            self.bottomSafeArea = bottomSafeArea
            self.topSafeArea = topSafeArea
        }
    }

    /// Vertical space available above the software keyboard. Equals
    /// ``Device/containerHeight`` when no keyboard is up.
    public struct Keyboard: Sendable, Equatable {
        public let availableHeight: CGFloat

        public init(availableHeight: CGFloat) {
            self.availableHeight = availableHeight
        }
    }

    /// User-driven inputs: the settled anchor and an optional live override
    /// (in-flight drag height, or snapshot-test freeze). Callers collapse
    /// drag vs. freeze before constructing; the resolver treats whichever
    /// is non-nil as the raw height.
    public struct Interaction: Sendable, Equatable {
        public let settledState: ChatPresentationState
        /// Live, in-flight chat-surface height. `nil` when not dragging
        /// (and no snapshot freeze applied), in which case the settled
        /// anchor's height is used. Drives `progress`, the snap envelope,
        /// and `crossedBelowEditorThreshold` — i.e. the anchor-space
        /// (keyboard-free) interpretation of the gesture.
        public let dragHeight: CGFloat?
        /// Live, in-flight chat-surface *top edge* in the keyboard-aware
        /// region's local space, captured at gesture start as
        /// `kbAwareH - renderedHeight` and updated as
        /// `startTopEdge + translation.height` (clamped). `nil` when not
        /// dragging. Drives ``renderedHeight`` directly during a drag so
        /// the visual top edge tracks the finger 1:1 — even from the
        /// capped semi-with-keyboard rest position, where ``dragHeight``
        /// alone would lift the chat off-finger.
        public let dragTopEdge: CGFloat?

        public init(
            settledState: ChatPresentationState,
            dragHeight: CGFloat?,
            dragTopEdge: CGFloat? = nil
        ) {
            self.settledState = settledState
            self.dragHeight = dragHeight
            self.dragTopEdge = dragTopEdge
        }
    }

    /// Reserved space above the semi-expanded chat surface in points,
    /// added to ``Device/topSafeArea`` to form the inset the semi anchor
    /// uses (so the drag handle lands flush under the backdrop applet's
    /// nav bar). 52pt matches `BibleNavBar`'s total height (the one
    /// backdrop applet today with a nav bar); for backdrops without a
    /// nav bar (Todo, the placeholders) the handle simply sits 52pt
    /// below the safe-area top — a Chat-side constant by design (no
    /// per-applet plumbing).
    public static let semiExpandedChromeReserve: CGFloat = 52

    /// Minimized-anchor height. The lower bound of ``effectiveHeight``.
    public let minHeight: CGFloat
    /// Expanded-anchor height. The upper bound of ``effectiveHeight``.
    public let maxHeight: CGFloat
    /// Resolved height of the supplied ``Interaction/settledState`` —
    /// the height the surface would rest at without any drag in flight.
    public let settledHeight: CGFloat
    /// The drag-or-settled height clamped to `[minHeight, maxHeight]`.
    /// Drives every morph interpolation (`progress`, composer chrome, …).
    public let effectiveHeight: CGFloat
    /// `[0, 1]` morph progress mapped from ``effectiveHeight`` —
    /// `0` = minimized pill, `1` = full-screen expanded.
    public let progress: Double
    /// `[0, 1]` progress at the semi-expanded anchor for the current
    /// device geometry — the mid-knot the host's backdrop dim curve
    /// reads. Lifted onto metrics so callers don't have to know about
    /// `topInset`.
    public let semiExpandedProgress: Double
    /// On-screen height of the bottom-pinned surface. Two regimes:
    /// during a drag (``Interaction/dragTopEdge`` is non-nil) the
    /// rendered height is `kbAwareH - dragTopEdge` so the visual top
    /// edge tracks the finger; otherwise ``effectiveHeight`` is clamped
    /// to ``Keyboard/availableHeight`` minus the semi top inset when
    /// settled at semi-expanded (so the handle holds its y under the
    /// keyboard). The only output that depends on the keyboard input.
    public let renderedHeight: CGFloat

    public init(device: Device, keyboard: Keyboard, interaction: Interaction) {
        let topInset = device.topSafeArea + Self.semiExpandedChromeReserve
        let minH = ChatPresentationState.minimized.height(
            in: device.containerHeight,
            bottomSafeArea: device.bottomSafeArea,
            topInset: topInset
        )
        let maxH = ChatPresentationState.expanded.height(
            in: device.containerHeight,
            bottomSafeArea: device.bottomSafeArea,
            topInset: topInset
        )
        let settledH = interaction.settledState.height(
            in: device.containerHeight,
            bottomSafeArea: device.bottomSafeArea,
            topInset: topInset
        )
        let rawH = interaction.dragHeight ?? settledH
        let effectiveH = min(maxH, max(minH, rawH))
        let resolvedProgress = ChatPresentationState.progress(
            forHeight: effectiveH,
            in: device.containerHeight,
            bottomSafeArea: device.bottomSafeArea,
            topInset: topInset
        )
        let semiProgress = ChatPresentationState.semiExpandedProgress(
            in: device.containerHeight,
            bottomSafeArea: device.bottomSafeArea,
            topInset: topInset
        )
        // Rendered-height resolution has two regimes:
        //
        // 1. **During a drag** — `dragTopEdge` is non-nil, captured at
        //    gesture start as `kbAwareH - renderedHeight` and tracked by
        //    `startTopEdge + translation.height`. The rendered height is
        //    `kbAwareH - dragTopEdge` so the visual top edge follows the
        //    finger 1:1, even from the capped semi-with-keyboard rest
        //    position (where the prior cap-vs-no-cap binary jumped the
        //    handle to y=0 the instant `dragHeight` flipped non-nil).
        //
        // 2. **Settled** — fall back to the keyboard-avoidance cap. The
        //    top-inset cap applies whenever the surface is settled at
        //    semi-expanded, so the handle holds its y under the keyboard.
        //    Every other settled state uses cap = 0 (top edge free to
        //    lift with the keyboard).
        let renderedH: CGFloat
        if let dragTopEdge = interaction.dragTopEdge {
            renderedH = max(0, keyboard.availableHeight - dragTopEdge)
        } else {
            let renderedCap: CGFloat = interaction.settledState == .semiExpanded ? topInset : 0
            renderedH = ChatPresentationState.renderedSurfaceHeight(
                effectiveHeight: effectiveH,
                keyboardAwareHeight: keyboard.availableHeight,
                topInsetCap: renderedCap
            )
        }

        self.minHeight = minH
        self.maxHeight = maxH
        self.settledHeight = settledH
        self.effectiveHeight = effectiveH
        self.progress = resolvedProgress
        self.semiExpandedProgress = semiProgress
        self.renderedHeight = renderedH
    }
}
