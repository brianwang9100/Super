/// Request-scoped Markdown retained while generating and awaiting a fresh database read.
public struct BibleAnnotationDraft: Sendable, Equatable {
    /// The original annotation request's correlation identifier.
    public let requestID: String
    /// Cumulative Markdown received from the generator.
    public var text: String
    /// Whether generation and its persistence write succeeded.
    public var isComplete: Bool

    public init(requestID: String, text: String = "", isComplete: Bool = false) {
        self.requestID = requestID
        self.text = text
        self.isComplete = isComplete
    }
}
