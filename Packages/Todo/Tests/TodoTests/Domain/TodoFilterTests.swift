import Foundation
import Testing
@testable import Todo

/// Tests for the pure `applyFilter` / `groupTasks` / `describe` logic and
/// `LabelHuePalette` hue allocation.
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
                priority: priority, state: state,
                dueAt: due,
                sortOrder: sortOrder,
                createdAt: createdAt ?? now,
                updatedAt: createdAt ?? now
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
        ]
        let out = applyFilter(TodoFilter(sort: .priority, state: .all), to: rows, now: now)
        #expect(out.map(\.id) == ["b", "c", "a"])
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

    @Test func groupByDueProducesTodayUpcomingNoDate() {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let rows = [
            task("today", due: today),
            task("soon", due: tomorrow),
            task("none", due: nil),
        ]
        let filter = TodoFilter(sort: .dueDate, state: .open)
        let filtered = applyFilter(filter, to: rows, now: today, calendar: calendar)
        let groups = groupTasks(filtered, filter: filter, now: today, calendar: calendar)
        #expect(groups.map(\.title) == ["Today", "Upcoming", "No date"])
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
