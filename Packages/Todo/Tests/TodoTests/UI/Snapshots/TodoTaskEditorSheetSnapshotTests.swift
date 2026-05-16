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
@Suite("TodoTaskEditorSheet snapshots")
@MainActor
struct TodoTaskEditorSheetSnapshotTests {
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

    private var labels: [LabelRecord] {
        [
            LabelRecord(id: "travel", name: "Travel", hue: 220, createdAt: now, updatedAt: now),
            LabelRecord(id: "work", name: "Work", hue: 200, createdAt: now, updatedAt: now),
        ]
    }

    private func verify(
        theme: SuperTheme.Identifier,
        mode: TodoScreenViewModel.DraftMode,
        draft: TaskDraft,
        fontScale: CGFloat = 1,
        name: String,
        function: String = #function
    ) {
        let resolved = SuperTheme.make(theme)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let view = TodoTaskEditorSheet(
            draft: .constant(draft),
            mode: mode,
            labels: labels,
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
