// Required for ValueObservationQueryable's inherited Publisher conformance;
// data observation remains owned by GRDBQuery, with no Combine data flow.
import Combine
import GRDB
import GRDBQuery

/// A loaded annotation query result carrying the completion token that caused its fetch.
struct AnnotationSheetSnapshot: Sendable, Equatable {
    let records: [BibleAnnotationRecord]
    let completedRequestID: String?
}

/// Refreshes the sheet after a completed write, distinguishing unloaded from empty results.
struct AnnotationSheetRequest: ValueObservationQueryable {
    static var defaultValue: AnnotationSheetSnapshot? { nil }

    var spec: BibleAnnotationTargetSpec
    var completedRequestID: String?

    func fetch(_ db: Database) throws -> AnnotationSheetSnapshot? {
        AnnotationSheetSnapshot(
            records: try BibleAnnotationsByTargetRequest(spec: spec).fetch(db),
            completedRequestID: completedRequestID
        )
    }
}
