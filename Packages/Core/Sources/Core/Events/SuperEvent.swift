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

    /// Bible requests a foreground annotation for this target. Chat streams
    /// Markdown and saves the completed response through `bible.annotate`.
    /// `reference.id` correlates progress and completion; no chat rows are created.
    case bibleAnnotateRequested(reference: RecordReference)

    /// Cumulative Markdown for a running foreground annotation request.
    case bibleAnnotateProgress(requestId: String, text: String)

    /// Completion of bibleAnnotateRequested; requestId is the original RecordReference.id.
    case bibleAnnotateCompleted(requestId: String, result: BibleAnnotateResult)

    /// Applets dismiss native sheets so the opening sidebar is not obscured.
    case sidebarOpened

    /// Controls the hamburger and minimized Chat pill while Chat is minimized.
    /// The shell restores chrome on applet changes or when Chat leaves the pill state.
    case shellChromeVisibilityRequested(visible: Bool)
}
