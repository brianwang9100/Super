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

        public init(containerHeight: CGFloat, bottomSafeArea: CGFloat) {
            self.containerHeight = containerHeight
            self.bottomSafeArea = bottomSafeArea
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
        /// anchor's height is used.
        public let dragHeight: CGFloat?

        public init(settledState: ChatPresentationState, dragHeight: CGFloat?) {
            self.settledState = settledState
            self.dragHeight = dragHeight
        }
    }

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
    /// On-screen height: ``effectiveHeight`` clamped to
    /// ``Keyboard/availableHeight``. The only output that depends on the
    /// keyboard input; the bottom-pinned surface uses it so the composer
    /// always rests above the keyboard's top edge.
    public let renderedHeight: CGFloat

    public init(device: Device, keyboard: Keyboard, interaction: Interaction) {
        let minH = ChatPresentationState.minimized.height(
            in: device.containerHeight,
            bottomSafeArea: device.bottomSafeArea
        )
        let maxH = ChatPresentationState.expanded.height(
            in: device.containerHeight,
            bottomSafeArea: device.bottomSafeArea
        )
        let settledH = interaction.settledState.height(
            in: device.containerHeight,
            bottomSafeArea: device.bottomSafeArea
        )
        let rawH = interaction.dragHeight ?? settledH
        let effectiveH = min(maxH, max(minH, rawH))
        let resolvedProgress = ChatPresentationState.progress(
            forHeight: effectiveH,
            in: device.containerHeight,
            bottomSafeArea: device.bottomSafeArea
        )
        let renderedH = ChatPresentationState.renderedSurfaceHeight(
            effectiveHeight: effectiveH,
            keyboardAwareHeight: keyboard.availableHeight
        )

        self.minHeight = minH
        self.maxHeight = maxH
        self.settledHeight = settledH
        self.effectiveHeight = effectiveH
        self.progress = resolvedProgress
        self.renderedHeight = renderedH
    }
}
