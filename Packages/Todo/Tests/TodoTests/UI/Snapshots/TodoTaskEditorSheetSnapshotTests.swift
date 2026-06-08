#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Todo

/// Snapshots for `TodoTaskEditorSheet`. The create-mode fixture renders an
/// empty draft (placeholder text, no state row or delete button); the
/// edit-mode fixture renders a fully-populated draft so the state row,
/// selected priority, selected due pill, and delete button are exercised.
///
/// `.serialized` matches every sibling Todo snapshot suite: image snapshots
/// read/write the shared on-disk `__Snapshots__/` directory and touch
/// process-global font registration, so the suites run serially to keep that
/// setup deterministic — not to paper over a race in the code under test.
@Suite("TodoTaskEditorSheet snapshots", .serialized)
@MainActor
struct TodoTaskEditorSheetSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("create mode, light") func createLight() {
        verify(theme: .light, mode: .create, draft: .empty, name: "editor_create_light")
    }

    @Test("create mode, dark") func createDark() {
        verify(theme: .dark, mode: .create, draft: .empty, name: "editor_create_dark")
    }

    @Test("create mode, sepia") func createSepia() {
        verify(theme: .sepia, mode: .create, draft: .empty, name: "editor_create_sepia")
    }

    @Test("edit mode, light") func editLight() {
        verify(theme: .light, mode: .edit, draft: populatedDraft, name: "editor_edit_light")
    }

    @Test("edit mode, dark") func editDark() {
        verify(theme: .dark, mode: .edit, draft: populatedDraft, name: "editor_edit_dark")
    }

    @Test("edit mode, sepia") func editSepia() {
        verify(theme: .sepia, mode: .edit, draft: populatedDraft, name: "editor_edit_sepia")
    }

    // The sheet scales its type through the app-wide `superFontScale`
    // slider rather than `@ScaledMetric`; this variant drives that path.
    @Test("create mode, large font scale") func createLargeFontScale() {
        verify(theme: .light, mode: .create, draft: .empty, fontScale: 1.5, name: "editor_create_light_large")
    }

    // A draft with enough labels that the chip row can't fit on one line —
    // the tag picker must wrap them rather than widen the whole sheet.
    // Captured in every theme so the wrapped chip colors are verified.
    @Test("labels wrap, light") func editManyLabels() {
        verify(theme: .light, mode: .edit, draft: manyLabelsDraft, labels: manyLabels,
               name: "editor_edit_many_labels")
    }

    @Test("labels wrap, dark") func editManyLabelsDark() {
        verify(theme: .dark, mode: .edit, draft: manyLabelsDraft, labels: manyLabels,
               name: "editor_edit_many_labels_dark")
    }

    @Test("labels wrap, sepia") func editManyLabelsSepia() {
        verify(theme: .sepia, mode: .edit, draft: manyLabelsDraft, labels: manyLabels,
               name: "editor_edit_many_labels_sepia")
    }

    // The `FlowLayout` chip wrap is font-sensitive — at a larger scale the
    // chips are wider and the row breaks at a different point. The existing
    // large-font variant uses an empty draft, so wrapping is never exercised
    // at scale.
    @Test("labels wrap, large font scale") func editManyLabelsLargeFontScale() {
        verify(theme: .light, mode: .edit, draft: manyLabelsDraft, labels: manyLabels,
               fontScale: 1.5, name: "editor_edit_many_labels_large")
    }

    // A custom (non-preset) due date: the "Pick…" pill shows the chosen
    // date rather than the neutral prompt, and reads as selected. Captured
    // in every theme so the pill's selected coloring is verified.
    @Test("custom due date, light") func editCustomDate() {
        verify(theme: .light, mode: .edit, draft: customDateDraft, name: "editor_edit_custom_date")
    }

    @Test("custom due date, dark") func editCustomDateDark() {
        verify(theme: .dark, mode: .edit, draft: customDateDraft, name: "editor_edit_custom_date_dark")
    }

    @Test("custom due date, sepia") func editCustomDateSepia() {
        verify(theme: .sepia, mode: .edit, draft: customDateDraft, name: "editor_edit_custom_date_sepia")
    }

    private var populatedDraft: TaskDraft {
        TaskDraft(
            id: "task-1",
            title: "Book hotel in Bologna",
            notes: "Walking distance to the conference venue.",
            priority: .high,
            dueAt: nil,
            state: .open,
            labelIds: ["travel"]
        )
    }

    private var manyLabelsDraft: TaskDraft {
        TaskDraft(
            id: "task-2",
            title: "Plan the quarterly offsite",
            notes: "",
            priority: .urgent,
            dueAt: nil,
            state: .open,
            labelIds: ["home", "finance", "health", "errands"]
        )
    }

    private var customDateDraft: TaskDraft {
        TaskDraft(
            id: "task-3",
            title: "Renew passport",
            notes: "",
            priority: .normal,
            dueAt: now.addingTimeInterval(4 * 86_400),
            state: .open,
            labelIds: []
        )
    }

    private var labels: [LabelRecord] {
        [
            LabelRecord(id: "travel", name: "Travel", hue: 220, createdAt: now, updatedAt: now),
            LabelRecord(id: "work", name: "Work", hue: 200, createdAt: now, updatedAt: now),
        ]
    }

    private var manyLabels: [LabelRecord] {
        [
            LabelRecord(id: "home", name: "Home improvement", hue: 230, createdAt: now, updatedAt: now),
            LabelRecord(id: "finance", name: "Finance", hue: 25, createdAt: now, updatedAt: now),
            LabelRecord(id: "health", name: "Health", hue: 150, createdAt: now, updatedAt: now),
            LabelRecord(id: "errands", name: "Errands", hue: 290, createdAt: now, updatedAt: now),
        ]
    }

    private func verify(
        theme: SuperTheme.Identifier,
        mode: TodoScreenViewModel.DraftMode,
        draft: TaskDraft,
        labels: [LabelRecord]? = nil,
        fontScale: CGFloat = 1,
        name: String,
        function: String = #function
    ) {
        let resolved = SuperTheme.make(theme)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let view = TodoTaskEditorSheet(
            title: .constant(draft.title),
            notes: .constant(draft.notes),
            priority: .constant(draft.priority),
            dueAt: .constant(draft.dueAt),
            labelIds: .constant(draft.labelIds),
            state: .constant(draft.state),
            mode: mode,
            labels: labels ?? self.labels,
            onSave: {},
            onCancel: {},
            onDelete: {},
            onCreateLabel: { _ in nil },
            now: now,
            calendar: utc
        )
        .frame(width: 402, height: 760, alignment: .top)
        .background(resolved.background)
        .superTheme(resolved)
        .superFontScale(fontScale)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 760)),
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
