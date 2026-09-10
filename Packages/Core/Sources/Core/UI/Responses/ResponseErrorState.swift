/// Action replaces Retry only when both actionLabel and action are set.
/// Equality ignores action closure identity.
public struct ResponseErrorState: Sendable, Equatable {
    /// Distinguishes origins so resolving one condition does not clear an unrelated error.
    public enum Kind: Sendable, Equatable {
        case generic
        case noModelConfigured
    }

    public let message: String
    public let detail: String?
    public let actionLabel: String?
    public let action: (@MainActor @Sendable () -> Void)?
    public let showsRetry: Bool
    public let kind: Kind

    public init(
        message: String,
        detail: String? = nil,
        actionLabel: String? = nil,
        action: (@MainActor @Sendable () -> Void)? = nil,
        showsRetry: Bool = true,
        kind: Kind = .generic
    ) {
        self.message = message
        self.detail = detail
        self.actionLabel = actionLabel
        self.action = action
        self.showsRetry = showsRetry
        self.kind = kind
    }

    public init(error: LLMError) {
        self.init(message: error.summary, detail: error.detail)
    }

    public static func == (lhs: ResponseErrorState, rhs: ResponseErrorState) -> Bool {
        lhs.message == rhs.message
            && lhs.detail == rhs.detail
            && lhs.actionLabel == rhs.actionLabel
            && lhs.showsRetry == rhs.showsRetry
            && lhs.kind == rhs.kind
    }
}
