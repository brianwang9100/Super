/// Broadcast envelope for the cross-applet event bus. One case today; new
/// cross-applet interactions append cases here rather than introducing
/// parallel channels.
public enum SuperEvent: Sendable, Equatable {
    /// An applet asks Chat to attach `reference` to its message composer.
    /// `startNewConversation` distinguishes "Add to chat" (`false`) from
    /// "New chat" (`true`) so the receiver can route accordingly.
    case recordAddedToChat(reference: RecordReference, startNewConversation: Bool)
}
