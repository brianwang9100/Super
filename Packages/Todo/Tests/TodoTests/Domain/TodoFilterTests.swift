import Foundation
import Testing
@testable import Todo

@Suite("TodoFilter")
struct TodoFilterTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Fixed UTC calendar so "same day" grouping is deterministic
    /// regardless of the machine's time zone.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func task(
        _ id: String,
        title: String = "x",
        priority: TaskPriority = .normal,
        state: TaskState = .open,
        due: Date? = nil,
        createdAt: Date? = nil,
        sortOrder: Double = 0,
        labels: [LabelRecord] = []
    ) -> TaskWithLabels {
        TaskWithLabels(
            task: TaskRecord(
                id: id, title: title,
                sortOrder: sortOrder,
                createdAt: createdAt ?? now,
                updatedAt: createdAt ?? now,
                priority: priority, state: state,
                dueAt: due
            ),
            labels: labels
        )
    }

    private func label(_ id: String, _ name: String) -> LabelRecord {
        LabelRecord(id: id, name: name, hue: 200, createdAt: now, updatedAt: now)
    }

    @Test func openStateScopeKeepsOnlyOpenTasks() {
        let rows = [task("a", state: .open), task("b", state: .done), task("c", state: .cancelled)]
        let out = applyFilter(TodoFilter(state: .open), to: rows, now: now)
        #expect(out.map(\.id) == ["a"])
    }

    @Test func allStateScopeReturnsEverything() {
        let rows = [task("a", state: .open), task("b", state: .done)]
        let out = applyFilter(TodoFilter(state: .all), to: rows, now: now)
        #expect(out.count == 2)
    }

    @Test("terminal state and label filters both apply", arguments: [TodoFilter.StateScope.done, .cancelled])
    func terminalStateAndLabelFiltersCombine(_ scope: TodoFilter.StateScope) {
        let work = label("work", "Work")
        let rows = [
            task("open", state: .open, labels: [work]),
            task("done", state: .done, labels: [work]),
            task("cancelled", state: .cancelled, labels: [work]),
            task("unlabelled-done", state: .done),
            task("unlabelled-cancelled", state: .cancelled),
        ]
        let out = applyFilter(TodoFilter(state: scope, labelIds: ["work"]), to: rows, now: now)
        #expect(out.map(\.id) == [scope == .done ? "done" : "cancelled"])
    }

    @Test func labelFilterIsOrSemantics() {
        let work = label("L1", "Work")
        let home = label("L2", "Home")
        let rows = [
            task("a", labels: [work]),
            task("b", labels: [home]),
            task("c", labels: []),
        ]
        let out = applyFilter(TodoFilter(state: .all, labelIds: ["L1", "L2"]), to: rows, now: now)
        #expect(Set(out.map(\.id)) == Set(["a", "b"]))
    }

    @Test func sortByPriorityOrdersUrgentFirst() {
        let rows = [
            task("a", priority: .normal),
            task("b", priority: .urgent),
            task("c", priority: .high),
            task("d", priority: .high, createdAt: now.addingTimeInterval(60)),
        ]
        let out = applyFilter(TodoFilter(sort: .priority, state: .all), to: rows, now: now)
        #expect(out.map(\.id) == ["b", "d", "c", "a"])
    }

    @Test func sortByNewestUsesCreatedAtDesc() {
        let rows = [
            task("a", createdAt: now),
            task("b", createdAt: now.addingTimeInterval(60)),
        ]
        let out = applyFilter(TodoFilter(sort: .newest, state: .all), to: rows, now: now)
        #expect(out.map(\.id) == ["b", "a"])
    }

    @Test func sortByManualUsesSortOrder() {
        let rows = [
            task("a", sortOrder: 2),
            task("b", sortOrder: 1),
        ]
        let out = applyFilter(TodoFilter(sort: .manual, state: .all), to: rows, now: now)
        #expect(out.map(\.id) == ["b", "a"])
    }

    @Test func groupByPriorityProducesThreeBuckets() {
        let today = calendar.startOfDay(for: now)
        let rows = [
            task("a", priority: .urgent),
            task("b", priority: .high),
            task("c", priority: .normal),
        ]
        let filter = TodoFilter(sort: .priority, state: .open)
        let filtered = applyFilter(filter, to: rows, now: today, calendar: calendar)
        let groups = groupTasks(filtered, filter: filter, now: today, calendar: calendar)
        #expect(groups.map(\.title) == ["Urgent", "High", "Normal"])
    }

    @Test func groupByDueIncludesOverdueAndLaterToday() {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let rows = [
            task("overdue", due: today.addingTimeInterval(-1)),
            task("today", due: tomorrow.addingTimeInterval(-1)),
            task("soon", due: tomorrow),
            task("none", due: nil),
        ]
        let filter = TodoFilter(sort: .dueDate, state: .open)
        let filtered = applyFilter(filter, to: rows, now: today, calendar: calendar)
        let groups = groupTasks(filtered, filter: filter, now: today, calendar: calendar)
        #expect(groups.map(\.title) == ["Today", "Upcoming", "No date"])
        #expect(groups.map { $0.tasks.map(\.id) } == [["overdue", "today"], ["soon"], ["none"]])
    }

    @Test func groupingOmitsEmptyBuckets() {
        let rows = [task("high", priority: .high)]
        let priorityGroups = groupTasks(rows, filter: TodoFilter(sort: .priority), now: now, calendar: calendar)
        #expect(priorityGroups.map(\.title) == ["High"])
        #expect(priorityGroups.flatMap(\.tasks).map(\.id) == ["high"])
        let dueGroups = groupTasks(rows, filter: TodoFilter(sort: .dueDate), now: now, calendar: calendar)
        #expect(dueGroups.map(\.title) == ["No date"])
        #expect(dueGroups.flatMap(\.tasks).map(\.id) == ["high"])
        for sort in [TodoFilter.Sort.priority, .dueDate] {
            #expect(groupTasks([], filter: TodoFilter(sort: sort), now: now, calendar: calendar).isEmpty)
        }
    }

    @Test func nonOpenScopesRemainUngrouped() {
        let rows = [task("done", state: .done), task("cancelled", state: .cancelled)]
        for sort in [TodoFilter.Sort.priority, .dueDate] {
            let groups = groupTasks(rows, filter: TodoFilter(sort: sort, state: .all), now: now, calendar: calendar)
            #expect(groups == [TodoListGroup(id: "_ungrouped", title: nil, tasks: rows)])
        }
    }

    @Test func sortByDueDateOrdersTodayThenUpcomingThenNoDate() {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let rows = [
            task("none", due: nil),
            task("soon", due: tomorrow),
            task("today", due: today),
        ]
        let out = applyFilter(
            TodoFilter(sort: .dueDate, state: .all), to: rows, now: today, calendar: calendar
        )
        #expect(out.map(\.id) == ["today", "soon", "none"])
    }

    @Test func describeSummary() {
        let filter = TodoFilter(sort: .priority, state: .open, labelIds: ["L1"])
        let lookup = ["L1": label("L1", "Work")]
        #expect(describe(filter, labelLookup: lookup) == "Open · Work · by priority")
    }

    @Test func describeUsesSingularTagWhenLabelUnresolved() {
        // A single selected label whose id is absent from the lookup must
        // read "1 tag", not the ungrammatical "1 tags".
        let filter = TodoFilter(state: .all, labelIds: ["missing"])
        #expect(describe(filter, labelLookup: [:]) == "All · 1 tag · by priority")
    }

    @Test func describePluralizesMultipleTags() {
        let filter = TodoFilter(state: .all, labelIds: ["a", "b"])
        #expect(describe(filter, labelLookup: [:]) == "All · 2 tags · by priority")
    }

    @Test func huePaletteSkipsUsedColors() {
        let used: Set<Double> = [220, 280]
        #expect(LabelHuePalette.nextHue(usedHues: used, existingCount: 2) == 25)
    }

    @Test func huePaletteRoundRobinsWhenPoolExhausted() {
        let used = Set(LabelHuePalette.pool)
        let next = LabelHuePalette.nextHue(usedHues: used, existingCount: LabelHuePalette.pool.count)
        #expect(next == LabelHuePalette.pool[0])
    }
}
