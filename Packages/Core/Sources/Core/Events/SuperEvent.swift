/// Broadcast envelope for the cross-applet event bus. New cross-applet
/// interactions append cases here rather than introducing parallel channels.
public enum SuperEvent: Sendable, Equatable {
    /// A credential owner saved, replaced, or removed its referenced secret.
    case credentialChanged(id: String)

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

    /// Any applet → shell: present a temporary record preview without navigating.
    /// Unsupported applet capabilities are ignored.
    case previewRecord(reference: RecordReference)

    /// Any applet → shell: focus the applet identified by
    /// `reference.appletID` and pass `reference` to it for in-applet
    /// navigation. Mirrors `recordAddedToChat` in reverse — that one
    /// pulls a record *into* Chat; this one pushes the user *back out*
    /// to the record's home applet. Bible receives external deep links,
    /// bookmark navigation, and explicit Open in Bible preview completions.
    case openRecord(reference: RecordReference)

    /// Bible requests a foreground annotation for this target. Chat streams
    /// Markdown and saves the completed response through `bible.annotate`.
    /// `reference.id` correlates progress and completion; no chat rows are created.
    case bibleAnnotateRequested(reference: RecordReference)

    /// Cumulative Markdown for a running foreground annotation request.
    case bibleAnnotateProgress(requestId: String, text: String)

    /// Chat → Bible (headless): a `bibleAnnotateRequested` dispatch
    /// terminated. `requestId` is the originating `RecordReference.id`.
    /// `result` is the outcome — Bible's view model uses it to remove
    /// the running entry from its dispatch table or surface a retry
    /// button.
    case bibleAnnotateCompleted(requestId: String, result: BibleAnnotateResult)

    /// Shell → applets: the navigation drawer (sidebar) is opening.
    /// Applets dismiss any native sheet they're presenting so the
    /// in-view drawer — which renders *below* a native sheet's own
    /// presentation window and would otherwise slide in behind it —
    /// becomes the topmost surface. Subscribers dismiss any native sheet
    /// they're presenting.
    case sidebarOpened

    /// Any applet → shell: hide (`visible: false`) or restore
    /// (`visible: true`) the shell's global chrome — the top-left
    /// hamburger button and the minimized chat pill — so a reading /
    /// content surface can claim the full screen. Deliberately
    /// applet-agnostic (Core stays domain-free): the applet decides *when*
    /// to ask; the shell decides *how* to comply. The shell honours it
    /// only while the chat is in its minimized pill state and resets to
    /// visible whenever the active applet changes or the chat leaves the
    /// pill, so a request can never strand chrome off-screen. Today's sole
    /// driver is the Bible reader hiding chrome as the user scrolls into a
    /// chapter and restoring it on scroll-up / at the top.
    case shellChromeVisibilityRequested(visible: Bool)
}
