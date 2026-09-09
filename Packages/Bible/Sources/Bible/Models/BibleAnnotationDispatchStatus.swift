import Foundation

/// Successful dispatches leave the status map; annotation queries supply their content.
public enum BibleAnnotationDispatchStatus: Sendable, Equatable {
    /// Correlates the request's RecordReference.id with bibleAnnotateCompleted.
    case running(requestId: String)

    case failed(message: String)
}
