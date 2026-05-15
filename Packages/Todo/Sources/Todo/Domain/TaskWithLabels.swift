import Foundation

/// View-model projection: a `TaskRecord` joined with its label rows. Built
/// in the view model after fetching from `TaskRepository` and
/// `TaskLabelRepository`; never persisted directly.
public struct TaskWithLabels: Sendable, Equatable, Identifiable {
    public var task: TaskRecord
    public var labels: [LabelRecord]

    public var id: String { task.id }

    public init(task: TaskRecord, labels: [LabelRecord]) {
        self.task = task
        self.labels = labels
    }
}
