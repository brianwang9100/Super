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

    /// Any applet → shell: focus the applet identified by
    /// `reference.appletID` and pass `reference` to it for in-applet
    /// navigation. Mirrors `recordAddedToChat` in reverse — that one
    /// pulls a record *into* Chat; this one pushes the user *back out*
    /// to the record's home applet. Today's sole consumer is Bible
    /// receiving a verse-range tap originating in the Chat transcript
    /// (and from `super://bible/...` deep links at the scene root).
    case openRecord(reference: RecordReference)

    /// Bible → Chat (headless): the user tapped a generation entry
    /// point (spark button on a verse selection, the Annotate action
    /// tile, an empty book-picker bubble) and Chat should fire a
    /// one-off LLM turn that calls the `bible.annotate` tool against
    /// the target encoded in `reference`. The turn must not be
    /// visible in the Chats list — the dispatcher creates a transient
    /// conversation, runs the turn, and cleans up the conversation
    /// rows when finished. `reference.id` is the request id the
    /// completion event will echo back.
    case bibleAnnotateRequested(reference: RecordReference)

    /// Chat → Bible (headless): a `bibleAnnotateRequested` dispatch
    /// terminated. `requestId` is the originating `RecordReference.id`.
    /// `result` is the outcome — Bible's view model uses it to remove
    /// the running entry from its dispatch table or surface a retry
    /// button.
    case bibleAnnotateCompleted(requestId: String, result: BibleAnnotateResult)
}
