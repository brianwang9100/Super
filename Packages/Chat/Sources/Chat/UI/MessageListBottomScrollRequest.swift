import Foundation

/// Bounds lazy-layout corrections to an explicit tap, without following later tokens.
struct MessageListBottomScrollRequest<Content: Equatable> {
    private var requestedContent: Content?
    private var attempts = 0

    mutating func begin(content: Content) {
        requestedContent = content
        attempts = 0
    }

    mutating func cancel() {
        requestedContent = nil
    }

    mutating func shouldRefine(distanceToBottom: CGFloat, isRendered: Bool, content: Content) -> Bool {
        guard let requestedContent else { return false }
        guard requestedContent == content, attempts < 4 else {
            cancel()
            return false
        }
        guard distanceToBottom > 2 else {
            // A lazy stack can report a provisional bottom before its final
            // turn materializes. Only that rendered turn can confirm arrival.
            if isRendered { cancel() }
            return false
        }
        attempts += 1
        return true
    }
}
