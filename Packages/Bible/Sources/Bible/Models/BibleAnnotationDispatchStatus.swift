import Foundation

/// Shared across readers. Successful requests remove their status; queried rows provide saved content.
public enum BibleAnnotationDispatchStatus: Sendable, Equatable {
    /// Correlates the request's RecordReference.id with bibleAnnotateCompleted.
    case running(requestId: String)

    case failed(message: String)
}
