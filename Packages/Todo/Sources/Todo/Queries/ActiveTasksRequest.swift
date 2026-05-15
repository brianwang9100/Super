// `import Combine` is mandatory, not stray: `ValueObservationQueryable`
// inherits `Queryable`, whose `ValuePublisher` associated type is
// `AnyPublisher<Value, any Error>`. Conforming a type to it requires the
// `AnyPublisher: Publisher` conformance to be visible in this file — the
// build fails without the import. No Combine data flow is used in our
// code; observation runs through GRDB's `ValueObservation` and `@Query`.
import Combine
import GRDB
import GRDBQuery

/// GRDBQuery request that observes every non-deleted task joined with its
/// labels, newest first. `@Query(ActiveTasksRequest())` in a SwiftUI view
/// re-renders automatically on any write to `task`, `taskLabel`, or
/// `label` — including writes from other applets (e.g. Chat creating a
/// task). This is the sanctioned GRDB→SwiftUI bridge; the view model does
/// not hand-roll observation.
public struct ActiveTasksRequest: ValueObservationQueryable {
    public static var defaultValue: [TaskWithLabels] { [] }

    public init() {}

    public func fetch(_ db: Database) throws -> [TaskWithLabels] {
        let tasks = try TaskRecord
            .filter(Column("deletedAt") == nil)
            .order(Column("createdAt").desc)
            .fetchAll(db)
        // Scope the join fetch to the tasks actually in view rather than
        // loading every join row and filtering in memory.
        let taskIDs = tasks.map(\.id)
        let joinRows = try TaskLabelRecord
            .filter(Column("deletedAt") == nil)
            .filter(taskIDs.contains(Column("taskId")))
            .fetchAll(db)
        // Fetch only the labels actually referenced by the in-view tasks'
        // join rows, not every active label.
        let labelIDs = Set(joinRows.map(\.labelId))
        let labelsByID = try Dictionary(
            uniqueKeysWithValues: LabelRecord
                .filter(Column("deletedAt") == nil)
                .filter(labelIDs.contains(Column("id")))
                .fetchAll(db)
                .map { ($0.id, $0) }
        )
        var labelsByTask: [String: [LabelRecord]] = [:]
        for join in joinRows {
            guard let label = labelsByID[join.labelId] else { continue }
            labelsByTask[join.taskId, default: []].append(label)
        }
        for taskID in labelsByTask.keys {
            labelsByTask[taskID]?.sort { $0.name.lowercased() < $1.name.lowercased() }
        }
        return tasks.map { TaskWithLabels(task: $0, labels: labelsByTask[$0.id] ?? []) }
    }
}
