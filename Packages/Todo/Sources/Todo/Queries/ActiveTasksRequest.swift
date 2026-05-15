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
        let joinRows = try TaskLabelRecord
            .filter(Column("deletedAt") == nil)
            .fetchAll(db)
        let labelsByID = try Dictionary(
            uniqueKeysWithValues: LabelRecord
                .filter(Column("deletedAt") == nil)
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
