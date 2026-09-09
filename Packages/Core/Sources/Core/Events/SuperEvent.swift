/// Cross-applet interactions share this event bus envelope.
public enum SuperEvent: Sendable, Equatable {
    /// A credential owner saved, replaced, or removed its referenced secret.
    case credentialChanged(id: String)

    /// Attaches to the current composer, or starts a new conversation when requested.
    case recordAddedToChat(reference: RecordReference, startNewConversation: Bool)

    /// The shell expands Chat and loads this conversation.
    case openConversationRequested(id: String)

    /// The shell expands Chat with a draft that is persisted on first use.
    case newConversationRequested

    /// The shell focuses `reference.appletID` and forwards the reference for navigation.
    case openRecord(reference: RecordReference)

    /// Runs a headless `bible.annotate` turn for `reference`; the transient conversation
    /// stays out of Chats and is deleted afterward. Completion echoes `reference.id`.
    case bibleAnnotateRequested(reference: RecordReference)

    /// Completes a headless annotation dispatch; `requestId` is its `RecordReference.id`.
    case bibleAnnotateCompleted(requestId: String, result: BibleAnnotateResult)

    /// Applets dismiss native sheets so the opening sidebar is not obscured.
    case sidebarOpened

    /// Controls the hamburger and minimized Chat pill while Chat is minimized.
    /// The shell restores chrome on applet changes or when Chat leaves the pill state.
    case shellChromeVisibilityRequested(visible: Bool)
}
