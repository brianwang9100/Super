#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Todo

/// Snapshots for `TodoTaskRow`. One stacked fixture per theme exercises the
/// row's visual states together — an open row with a due-today badge and
/// label chips, an open row with an upcoming due date, a completed (muted)
/// row, and a cancelled (strikethrough) row — plus a larger Dynamic Type
/// size. `now` / `calendar` are fixed so the due badges are deterministic.
@Suite("TodoTaskRow snapshots", .serialized)
@MainActor
struct TodoTaskRowSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    @Test("light theme") func light() {
        verify(theme: .light, name: "task_row_light")
    }

    @Test("dark theme") func dark() {
        verify(theme: .dark, name: "task_row_dark")
    }

    @Test("sepia theme") func sepia() {
        verify(theme: .sepia, name: "task_row_sepia")
    }

    @Test("dynamic type XXL") func dynamicTypeXXL() {
        verify(theme: .light, dynamicType: .xxLarge, name: "task_row_light_xxl")
    }

    private func label(_ id: String, _ name: String, hue: Double) -> LabelRecord {
        LabelRecord(id: id, name: name, hue: hue, createdAt: now, updatedAt: now)
    }

    private func row(
        _ id: String,
        _ title: String,
        priority: TaskPriority,
        state: TaskState,
        due: Date?,
        labels: [LabelRecord]
    ) -> TaskWithLabels {
        TaskWithLabels(
            task: TaskRecord(
                id: id, title: title,
                sortOrder: 0, createdAt: now, updatedAt: now,
                priority: priority, state: state, dueAt: due
            ),
            labels: labels
        )
    }

    private func verify(
        theme: SuperTheme.Identifier,
        dynamicType: DynamicTypeSize = .large,
        name: String,
        function: String = #function
    ) {
        let resolved = SuperTheme.make(theme)
        let rows = [
            row("1", "Book hotel in Bologna", priority: .urgent, state: .open,
                due: now, labels: [label("travel", "Travel", hue: 220)]),
            row("2", "Draft Q3 OKRs", priority: .high, state: .open,
                due: now.addingTimeInterval(3 * 86_400),
                labels: [label("work", "Work", hue: 200), label("admin", "Admin", hue: 280)]),
            row("3", "Buy travel adapter", priority: .normal, state: .done,
                due: nil, labels: []),
            row("4", "Schedule annual physical", priority: .high, state: .cancelled,
                due: nil, labels: [label("health", "Health", hue: 150)]),
        ]
        let view = VStack(spacing: 8) {
            ForEach(rows) { row in
                TodoTaskRow(row: row, now: now, calendar: utc, onToggleState: { _ in }, onPress: { _ in })
            }
        }
        .padding(14)
        .frame(width: 402, height: 380, alignment: .top)
        .background(resolved.background)
        .superTheme(resolved)
        .dynamicTypeSize(dynamicType)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 380)),
            named: name,
            record: SnapshotEnvironment.isRecording ? .all : nil,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
