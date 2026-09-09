import Core

/// An ordered reference handoff for the current composer or a new conversation.
public struct ComposerAttentionRequest: Sendable, Equatable {
    /// Whether to create a conversation before attaching this batch.
    public let startNew: Bool
    /// References owned by this request, never drained by an unrelated composer.
    public let references: [RecordReference]

    /// Creates a destination-bound reference batch.
    public init(startNew: Bool, references: [RecordReference]) {
        self.startNew = startNew
        self.references = references
    }
}
