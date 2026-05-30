import Foundation

/// In-flight or terminal state of a headless `bible.annotate` dispatch
/// for a given target.
///
/// `BibleScreenViewModel` keeps a `[BibleAnnotationTargetSpec: BibleAnnotationDispatchStatus]`
/// map so the annotation sheet can show a generating indicator while a
/// turn is in progress and a retry button when the turn failed.
/// Successful dispatches drop their entry — rows arrive through the
/// reactive `@Query`, so the sheet flips from "generating" to "populated"
/// the same way an in-chat tool call would.
public enum BibleAnnotationDispatchStatus: Sendable, Equatable {
    /// A dispatch is in flight. `requestId` is the `RecordReference.id`
    /// the view model used when it published
    /// `SuperEvent.bibleAnnotateRequested`, so the matching
    /// `bibleAnnotateCompleted` envelope can be paired back to the
    /// originating target.
    case running(requestId: String)

    /// A dispatch failed terminally. `message` is the short
    /// human-readable reason the sheet's retry state shows above the
    /// "Try again" button.
    case failed(message: String)
}
