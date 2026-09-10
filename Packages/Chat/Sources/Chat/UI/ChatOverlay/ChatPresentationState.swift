import Core
import SwiftUI

/// Settled anchors only; the overlay owns continuous drag geometry.
public enum ChatPresentationState: Sendable, Equatable, CaseIterable {
    case expanded

    case semiExpanded

    case minimized
}

extension ChatPresentationState {
    /// Excludes the bottom safe-area inset; avoid slack that separates the handle from the pill.
    public static let minimizedBaseHeight: CGFloat = 60

    public static let semiExpandedMinHeight: CGFloat = 280

    /// bottomSafeArea raises the minimized pill above the home indicator.
    /// topInset reserves backdrop chrome only for the semi-expanded anchor.
    public func height(
        in containerHeight: CGFloat,
        bottomSafeArea: CGFloat = 0,
        topInset: CGFloat = 0
    ) -> CGFloat {
        switch self {
        case .minimized:
            return Self.minimizedBaseHeight + bottomSafeArea
        case .semiExpanded:
            return max(Self.semiExpandedMinHeight, containerHeight - topInset)
        case .expanded:
            return containerHeight
        }
    }
}

extension ChatPresentationState {
    /// Use the same topInset as layout so a release does not jump to a different semi anchor.
    public static func nearestAnchor(
        forHeight height: CGFloat,
        in containerHeight: CGFloat,
        bottomSafeArea: CGFloat = 0,
        topInset: CGFloat = 0
    ) -> ChatPresentationState {
        let scored: [(state: ChatPresentationState, delta: CGFloat)] = Self.allCases.map { state in
            (state, abs(state.height(in: containerHeight, bottomSafeArea: bottomSafeArea, topInset: topInset) - height))
        }
        return scored.min(by: { $0.delta < $1.delta })?.state ?? .semiExpanded
    }

    /// Threshold in predicted remaining translation points, not points per second.
    public static let skipVelocity: CGFloat = 1_200

    /// velocity is predictedEndTranslation.height minus translation.height.
    /// Positive collapses; negative expands. Hard flicks skip to the endpoint anchor.
    public static func snapTarget(
        currentHeight: CGFloat,
        velocity: CGFloat,
        containerHeight: CGFloat,
        bottomSafeArea: CGFloat = 0,
        topInset: CGFloat = 0
    ) -> ChatPresentationState {
        if abs(velocity) >= Self.skipVelocity {
            return velocity > 0 ? .minimized : .expanded
        }
        let projectedHeight = currentHeight - velocity
        return nearestAnchor(
            forHeight: projectedHeight,
            in: containerHeight,
            bottomSafeArea: bottomSafeArea,
            topInset: topInset
        )
    }
}

extension ChatPresentationState {
    /// Pair editor > threshold with pill <= threshold so the boundary has a live tap target.
    public static let editorInteractiveThreshold: Double = 0.15

    public static func crossedBelowEditorThreshold(
        from oldProgress: Double,
        to newProgress: Double
    ) -> Bool {
        oldProgress > editorInteractiveThreshold
            && newProgress <= editorInteractiveThreshold
    }

    /// Zero is minimized and one expanded; semi-expanded progress depends on container geometry.
    public static func progress(
        forHeight height: CGFloat,
        in containerHeight: CGFloat,
        bottomSafeArea: CGFloat = 0,
        topInset: CGFloat = 0
    ) -> Double {
        let minH = ChatPresentationState.minimized.height(in: containerHeight, bottomSafeArea: bottomSafeArea, topInset: topInset)
        let maxH = ChatPresentationState.expanded.height(in: containerHeight, bottomSafeArea: bottomSafeArea, topInset: topInset)
        guard maxH > minH else { return 0 }
        let raw = Double((height - minH) / (maxH - minH))
        return min(1, max(0, raw))
    }

    public static func semiExpandedProgress(
        in containerHeight: CGFloat,
        bottomSafeArea: CGFloat = 0,
        topInset: CGFloat = 0
    ) -> Double {
        let semiH = semiExpanded.height(in: containerHeight, bottomSafeArea: bottomSafeArea, topInset: topInset)
        return progress(forHeight: semiH, in: containerHeight, bottomSafeArea: bottomSafeArea, topInset: topInset)
    }
}

extension ChatPresentationState {
    /// Cap visible height without changing keyboard-free anchor math.
    /// Set topInsetCap for the semi anchor to keep its handle fixed as the keyboard rises.
    public static func renderedSurfaceHeight(
        effectiveHeight: CGFloat,
        keyboardAwareHeight: CGFloat,
        topInsetCap: CGFloat = 0
    ) -> CGFloat {
        // Short windows or full-height keyboards can leave less space than the inset.
        max(0, min(effectiveHeight, keyboardAwareHeight - topInsetCap))
    }
}
