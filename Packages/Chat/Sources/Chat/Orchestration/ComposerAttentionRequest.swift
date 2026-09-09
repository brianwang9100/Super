import Core

/// Owns an ordered reference batch so another composer cannot drain it.
public struct ComposerAttentionRequest: Sendable, Equatable {
    public let startNew: Bool
    public let references: [RecordReference]

    public init(startNew: Bool, references: [RecordReference]) {
        self.startNew = startNew
        self.references = references
    }
}
