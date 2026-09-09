import Foundation

/// Bounds correction to the tapped turn/layout context and stops at rendered arrival.
struct MessageListBottomScrollRequest<Content: Equatable> {
    private var requestedContent: Content?
    private var attempts = 0
    private var animated = false
    private var isAnimating = false
    private var nativeMotionBegan = false
    private var minimumMeasurementID = 0
    private(set) var movementID = 0

    mutating func begin(content: Content, animated: Bool = false) {
        requestedContent = content
        attempts = 0
        self.animated = animated
        minimumMeasurementID = 0
        beginMovement()
    }

    mutating func motionBegan() {
        guard requestedContent != nil, animated else { return }
        isAnimating = true
        nativeMotionBegan = true
    }

    mutating func motionEnded(awaiting measurementID: Int) -> Bool {
        guard requestedContent != nil, isAnimating else { return false }
        isAnimating = false
        nativeMotionBegan = false
        minimumMeasurementID = measurementID
        return true
    }

    /// Reconcile a no-op seek; actual native motion remains owned by scroll phases.
    mutating func animationCompleted(for movementID: Int, awaiting measurementID: Int) -> Bool {
        guard movementID == self.movementID, !nativeMotionBegan else { return false }
        return motionEnded(awaiting: measurementID)
    }

    mutating func cancel() {
        requestedContent = nil
        isAnimating = false
        nativeMotionBegan = false
    }

    mutating func shouldRefine(
        distanceToBottom: CGFloat, isRendered: Bool, content: Content, measurementID: Int = 0
    ) -> Bool {
        guard let requestedContent else { return false }
        guard requestedContent == content else {
            cancel()
            return false
        }
        // Both stack estimates and the rendered turn must retain this lower
        // bound: one fresh estimate cannot validate an older rendered sample.
        guard !isAnimating, measurementID >= minimumMeasurementID else { return false }
        guard distanceToBottom > 2 else {
            // A lazy stack can report a provisional bottom before its final
            // turn materializes. Only that rendered turn can confirm arrival.
            if isRendered { cancel() }
            return false
        }
        guard attempts < 4 else {
            cancel()
            return false
        }
        attempts += 1
        beginMovement()
        return true
    }

    private mutating func beginMovement() {
        movementID += 1
        isAnimating = animated
        nativeMotionBegan = false
    }
}
