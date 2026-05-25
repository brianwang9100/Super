/// Broadcast envelope for the cross-applet event bus. New cross-applet
/// interactions append cases here rather than introducing parallel channels.
public enum SuperEvent: Sendable, Equatable {
    /// An applet asks Chat to attach `reference` to its message composer.
    /// `startNewConversation` distinguishes "Add to chat" (`false`) from
    /// "New chat" (`true`) so the receiver can route accordingly.
    case recordAddedToChat(reference: RecordReference, startNewConversation: Bool)

    /// Chats applet → shell: open the conversation with this id in the
    /// chat overlay. The shell handles snapping the overlay to expanded
    /// and rebuilding the per-conversation view model.
    case openConversationRequested(id: String)

    /// Chats applet → shell: create a fresh "New chat" draft in the
    /// overlay. The shell handles allocating an id, snapping to expanded,
    /// and routing through the existing lazy-persist driver.
    case newConversationRequested
}
