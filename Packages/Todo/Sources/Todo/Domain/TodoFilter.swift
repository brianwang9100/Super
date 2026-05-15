import Foundation

/// The user's active sort and filter across the task list. State is
/// in-memory only for the MVP; persisting it across launches is a
/// follow-up.
public struct TodoFilter: Sendable, Equatable {
    /// Sort order. `.manual` stays in the enum so a future reorder UX can
    /// adopt it without a schema change, but the filter sheet does not
    /// expose it yet.
    public enum Sort: String, Sendable, Equatable, CaseIterable {
        case priority
        case dueDate
        case newest
        case manual

        public var displayName: String {
            switch self {
            case .priority: "priority"
            case .dueDate:  "due"
            case .newest:   "newest"
            case .manual:   "manual"
            }
        }
    }

    /// Which task states the list shows.
    public enum StateScope: Sendable, Equatable {
        case open
        case done
        case cancelled
        case all

        public var displayName: String {
            switch self {
            case .open:      "Open"
            case .done:      "Completed"
            case .cancelled: "Cancelled"
            case .all:       "All"
            }
        }
    }

    public var sort: Sort
    public var state: StateScope
    /// Selected label ids — OR semantics: a task matches if it carries any
    /// one of them. A `Set` because the selection is order-independent and
    /// a label cannot be selected twice.
    public var labelIds: Set<String>

    public init(
        sort: Sort = .priority,
        state: StateScope = .open,
        labelIds: Set<String> = []
    ) {
        self.sort = sort
        self.state = state
        self.labelIds = labelIds
    }

    public static let defaults = TodoFilter()
}

/// Filter and sort the task list. Pure — used by the view model and
/// unit-tested in isolation. `calendar` is injected (rather than read from
/// `Calendar.current`) so "due today" stays deterministic across time
/// zones and under test.
public func applyFilter(
    _ filter: TodoFilter,
    to tasks: [TaskWithLabels],
    now: Date,
    calendar: Calendar = .current
) -> [TaskWithLabels] {
    var out = tasks
    switch filter.state {
    case .open:      out = out.filter { $0.task.state == .open }
    case .done:      out = out.filter { $0.task.state == .done }
    case .cancelled: out = out.filter { $0.task.state == .cancelled }
    case .all:       break
    }
    if !filter.labelIds.isEmpty {
        out = out.filter { row in
            row.labels.contains { filter.labelIds.contains($0.id) }
        }
    }
    switch filter.sort {
    case .priority:
        out.sort { lhs, rhs in
            if lhs.task.priority != rhs.task.priority {
                return lhs.task.priority < rhs.task.priority
            }
            return lhs.task.createdAt > rhs.task.createdAt
        }
    case .dueDate:
        out.sort {
            dueRank($0.task.dueAt, now: now, calendar: calendar)
                < dueRank($1.task.dueAt, now: now, calendar: calendar)
        }
    case .newest:
        out.sort { $0.task.createdAt > $1.task.createdAt }
    case .manual:
        out.sort { $0.task.sortOrder < $1.task.sortOrder }
    }
    return out
}

/// 0 = due today or overdue, 1 = due in the future, 2 = no due date.
/// "Today" is measured against the injected `now` and `calendar`, not the
/// wall clock or device time zone, so the logic stays deterministic.
private func dueRank(_ date: Date?, now: Date, calendar: Calendar) -> Int {
    guard let date else { return 2 }
    if calendar.isDate(date, inSameDayAs: now) { return 0 }
    return date > now ? 1 : 0
}

/// One grouped section of the task list. The view model returns one per
/// visible group; `title == nil` means the group renders without a header.
public struct TodoListGroup: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String?
    public let tasks: [TaskWithLabels]

    public init(id: String, title: String?, tasks: [TaskWithLabels]) {
        self.id = id
        self.title = title
        self.tasks = tasks
    }
}

/// Group a filtered task array per the design's rules: priority sort with
/// open state groups by Urgent / High / Normal; due-date sort with open
/// state groups by Today / Upcoming / No date; every other combination is
/// a single header-less group. `calendar` is injected for the same
/// determinism reason as `applyFilter`.
public func groupTasks(
    _ tasks: [TaskWithLabels],
    filter: TodoFilter,
    now: Date,
    calendar: Calendar = .current
) -> [TodoListGroup] {
    if filter.sort == .priority && filter.state == .open {
        var byPriority: [TaskPriority: [TaskWithLabels]] = [:]
        for row in tasks { byPriority[row.task.priority, default: []].append(row) }
        return TaskPriority.allCases.compactMap { priority in
            let rows = byPriority[priority] ?? []
            guard !rows.isEmpty else { return nil }
            return TodoListGroup(id: "p\(priority.rawValue)", title: priority.displayName, tasks: rows)
        }
    }
    if filter.sort == .dueDate && filter.state == .open {
        var today: [TaskWithLabels] = []
        var upcoming: [TaskWithLabels] = []
        var noDate: [TaskWithLabels] = []
        for row in tasks {
            if let due = row.task.dueAt {
                if calendar.isDate(due, inSameDayAs: now) || due < now { today.append(row) }
                else { upcoming.append(row) }
            } else {
                noDate.append(row)
            }
        }
        var groups: [TodoListGroup] = []
        if !today.isEmpty { groups.append(TodoListGroup(id: "today", title: "Today", tasks: today)) }
        if !upcoming.isEmpty { groups.append(TodoListGroup(id: "soon", title: "Upcoming", tasks: upcoming)) }
        if !noDate.isEmpty { groups.append(TodoListGroup(id: "none", title: "No date", tasks: noDate)) }
        return groups
    }
    return [TodoListGroup(id: "_ungrouped", title: nil, tasks: tasks)]
}

/// One-line human summary of the filter, rendered in the filter pill.
public func describe(_ filter: TodoFilter, labelLookup: [String: LabelRecord]) -> String {
    var parts: [String] = [filter.state.displayName]
    if !filter.labelIds.isEmpty {
        if filter.labelIds.count == 1,
           let id = filter.labelIds.first,
           let label = labelLookup[id] {
            parts.append(label.name)
        } else {
            let count = filter.labelIds.count
            parts.append("\(count) tag\(count == 1 ? "" : "s")")
        }
    }
    parts.append("by \(filter.sort.displayName)")
    return parts.joined(separator: " · ")
}
