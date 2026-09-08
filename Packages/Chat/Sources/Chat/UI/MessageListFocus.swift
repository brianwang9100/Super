import Foundation

/// Serializes explicit focus moves without observing or following response growth.
/// Kept non-observable so geometry and animation callbacks never invalidate layout.
final class MessageListFocus {
    struct Move: Equatable {
        let request: MessageList.ScrollRequest
        let animated: Bool
    }

    struct Geometry: Equatable {
        let request: MessageList.ScrollRequest
        let viewportY: CGFloat
        let measurementID: Int

        init(request: MessageList.ScrollRequest, viewportY: CGFloat, measurementID: Int = 0) {
            self.request = request
            self.viewportY = viewportY
            self.measurementID = measurementID
        }
    }

    private var current: MessageList.ScrollRequest?
    private var completed: MessageList.ScrollRequest?
    private var geometry: Geometry?
    private var pendingGeometry: Geometry?
    private var attempts = 0
    private var animated = false
    private var isAnimating = false
    private var awaitingMeasurementID: Int?

    func begin(_ request: MessageList.ScrollRequest, animated: Bool) -> Move? {
        guard completed != request else { return nil }
        current = request
        geometry = pendingGeometry?.request == request ? pendingGeometry : nil
        pendingGeometry = nil
        attempts = 0
        self.animated = animated
        isAnimating = false
        awaitingMeasurementID = nil
        return seek()
    }

    func measure(_ measurement: Geometry) -> Move? {
        guard measurement.request == current else {
            // SwiftUI can deliver a new target's geometry before onChange.
            pendingGeometry = measurement
            return nil
        }
        geometry = measurement
        if let awaitingMeasurementID {
            guard measurement.measurementID == awaitingMeasurementID else { return nil }
            self.awaitingMeasurementID = nil
        }
        return refine()
    }

    func motionBegan() {
        guard current != completed else { return }
        isAnimating = true
    }

    /// Ask the view for a fresh layout sample; cached geometry may predate idle.
    func motionEnded(awaiting measurementID: Int) -> Bool {
        guard isAnimating, current != completed else { return false }
        isAnimating = false
        awaitingMeasurementID = measurementID
        return true
    }

    func cancel() {
        completed = current
        isAnimating = false
        awaitingMeasurementID = nil
    }

    private func seek() -> Move? {
        guard let current else { return nil }
        if let geometry, abs(geometry.viewportY) <= 9 {
            completed = current
            return nil
        }
        isAnimating = animated
        return Move(request: current, animated: animated)
    }

    private func refine() -> Move? {
        guard let geometry, let current, completed != current, !isAnimating else { return nil }
        // Evaluate final geometry, never intermediate animation frames: an
        // estimated lazy target can cross the actual top and finish beyond it.
        if abs(geometry.viewportY) <= 9 || attempts >= 4 {
            completed = current
            return nil
        }
        attempts += 1
        return seek()
    }
}
