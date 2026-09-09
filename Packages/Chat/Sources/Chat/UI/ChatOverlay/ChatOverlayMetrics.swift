import SwiftUI

/// Resolve anchor geometry independently of keyboard avoidance; only renderedHeight uses keyboard input.
public struct ChatOverlayMetrics: Sendable, Equatable {
    /// All device geometry excludes the software keyboard.
    public struct Device: Sendable, Equatable {
        public let containerHeight: CGFloat
        public let bottomSafeArea: CGFloat
        public let topSafeArea: CGFloat

        public init(containerHeight: CGFloat, bottomSafeArea: CGFloat, topSafeArea: CGFloat = 0) {
            self.containerHeight = containerHeight
            self.bottomSafeArea = bottomSafeArea
            self.topSafeArea = topSafeArea
        }
    }

    /// Available space above the keyboard; equals containerHeight when hidden.
    public struct Keyboard: Sendable, Equatable {
        public let availableHeight: CGFloat

        public init(availableHeight: CGFloat) {
            self.availableHeight = availableHeight
        }
    }

    public struct Interaction: Sendable, Equatable {
        public let settledState: ChatPresentationState
        /// Keyboard-free anchor height, or nil to use the settled anchor.
        public let dragHeight: CGFloat?
        /// Top edge in keyboard-aware local coordinates. During a drag, this bypasses
        /// the settled inset cap so the handle stays under the finger.
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

    /// Matches BibleNavBar height, reserved for every backdrop without per-applet coupling.
    public static let semiExpandedChromeReserve: CGFloat = 52

    public let minHeight: CGFloat
    public let maxHeight: CGFloat
    public let settledHeight: CGFloat
    /// Clamped anchor height used by morph interpolation.
    public let effectiveHeight: CGFloat
    /// Zero is minimized; one is fully expanded.
    public let progress: Double
    public let semiExpandedProgress: Double
    /// Keyboard-aware visible height; during a drag, derive it from dragTopEdge.
    /// At rest, cap to available space while preserving the semi anchor's top inset.
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
