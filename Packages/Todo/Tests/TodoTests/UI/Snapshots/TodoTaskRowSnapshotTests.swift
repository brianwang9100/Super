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
    init() { SnapshotFontRegistration.ensureRegistered() }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    @Test("light theme") func light() {
        verify(theme: .vellumLight, name: "task_row_light")
    }

    @Test("dark theme") func dark() {
        verify(theme: .vellumDark, name: "task_row_dark")
    }

    @Test("sepia theme") func sepia() {
        verify(theme: .sepiaLight, name: "task_row_sepia")
    }

    @Test("dynamic type XXL") func dynamicTypeXXL() {
        verify(theme: .vellumLight, dynamicType: .xxLarge, name: "task_row_light_xxl")
    }

    // A row with more labels than fit on one line: the chips must keep
    // their natural width (no text-wrapping) and the overflow collapses to
    // a trailing "…", with the due badge still pinned at the end. Captured
    // in every theme so the chip and ellipsis colors are verified.
    @Test("many labels truncate, light") func manyLabels() {
        verify(theme: .vellumLight, rows: manyLabelRows, height: 190, name: "task_row_many_labels")
    }

    @Test("many labels truncate, dark") func manyLabelsDark() {
        verify(theme: .vellumDark, rows: manyLabelRows, height: 190, name: "task_row_many_labels_dark")
    }

    @Test("many labels truncate, sepia") func manyLabelsSepia() {
        verify(theme: .sepiaLight, rows: manyLabelRows, height: 190, name: "task_row_many_labels_sepia")
    }

    // At XXL the chips are physically wider, so fewer fit and the
    // truncation point shifts — `TruncatingRowLayout` must still keep chips
    // at natural width and pin the due badge. The default-type variants
    // above can't catch a Dynamic-Type regression in the new layout.
    @Test("many labels truncate, dynamic type XXL") func manyLabelsXXL() {
        verify(theme: .vellumLight, dynamicType: .xxLarge, rows: manyLabelRows, height: 260,
               name: "task_row_many_labels_xxl")
    }

    /// Two rows that each carry more labels than one line can hold — one
    /// with a due date, one without — to exercise `TruncatingRowLayout`.
    private var manyLabelRows: [TaskWithLabels] {
        let many = [
            label("l0", "Home improvement", hue: 40),
            label("l1", "Finance", hue: 290),
            label("l2", "Health", hue: 10),
            label("l3", "Travel", hue: 230),
            label("l4", "Errands", hue: 25),
            label("l5", "Work", hue: 150),
            label("l6", "Family", hue: 190),
            label("l7", "Personal", hue: 270),
        ]
        return [
            row("m1", "Renew driver's license", priority: .urgent, state: .open, due: now, labels: many),
            row("m2", "Sort the garage", priority: .normal, state: .open, due: nil, labels: many),
        ]
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

    /// The default fixture: an open due-today row with a chip, an open
    /// upcoming row with two chips, a completed (muted) row, and a
    /// cancelled (strikethrough) row.
    private var standardRows: [TaskWithLabels] {
        [
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
    }

    private func verify(
        theme: SuperTheme.Identifier,
        dynamicType: DynamicTypeSize = .large,
        rows: [TaskWithLabels]? = nil,
        height: CGFloat = 380,
        name: String,
        function: String = #function
    ) {
        let resolved = SuperTheme.make(theme)
        let view = VStack(spacing: 8) {
            ForEach(rows ?? standardRows) { row in
                TodoTaskRow(row: row, now: now, calendar: utc, onToggleState: { _ in }, onPress: { _ in })
            }
        }
        .padding(14)
        .frame(width: 402, height: height, alignment: .top)
        .background(resolved.background)
        .superTheme(resolved)
        .dynamicTypeSize(dynamicType)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: height)),
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
