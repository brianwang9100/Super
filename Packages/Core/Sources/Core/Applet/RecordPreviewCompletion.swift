/// The action to perform after an applet's temporary record preview has dismissed.
public enum RecordPreviewCompletion: Sendable, Equatable {
    /// Return to the prior screen without navigation.
    case cancel
    /// Open the captured reference in its full applet.
    case openRecord(reference: RecordReference)
    /// Attach the captured reference to the current or a new conversation.
    case addToChat(reference: RecordReference, startNewConversation: Bool)
}
