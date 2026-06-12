/// Terminal outcome of a one-off `bible.annotate` dispatch fired in
/// response to a `SuperEvent.bibleAnnotateRequested` event.
///
/// Carried back to the requester through `SuperEvent.bibleAnnotateCompleted`.
/// The shape is deliberately generic — `annotationCount` is whatever the
/// dispatcher observed land in the Bible database during the turn, and
/// `message` is the short human-facing failure reason the Bible UI shows
/// next to its retry button. Keep it equatable so `SuperEvent` stays
/// equatable.
public enum BibleAnnotateResult: Sendable, Equatable {
    /// The LLM called `bible.annotate` and the tool wrote the listed
    /// number of rows — always 1 per call since the single-summary
    /// redesign (the tool writes one markdown summary per target). The
    /// count survives as API shape, not information; mirrors
    /// `BibleAnnotateOutcome.success`.
    case success(annotationCount: Int)

    /// The dispatch did not produce annotations. `message` is a short
    /// human-readable reason — surfaced verbatim next to the retry
    /// button on the Bible UI.
    case failure(message: String)
}
