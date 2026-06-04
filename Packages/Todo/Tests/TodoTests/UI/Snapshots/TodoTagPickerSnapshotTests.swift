#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Todo

/// Snapshots for `TodoTagPicker` — the glass input field, the frosted
/// suggestion chips, and the accent call-to-action "＋ Create" affordance.
/// The create affordance and filtered suggestions are seeded through the
/// `initialQuery` test seam (the field's query is otherwise internal state).
@Suite("TodoTagPicker snapshots", .serialized)
@MainActor
struct TodoTagPickerSnapshotTests {
    /// Empty query: the glass input field with one selected chip plus the
    /// frosted suggestion chips for the unselected pool.
    @Test("suggestions, light") func suggestionsLight() {
        verify(theme: .light, query: "", name: "tag_picker_suggestions_light")
    }

    /// Typed query with no exact match: the accent "＋ Create" call-to-action
    /// glass, across the three themes.
    @Test("create affordance, light") func createLight() {
        verify(theme: .light, query: "Groceries", name: "tag_picker_create_light")
    }

    @Test("create affordance, dark") func createDark() {
        verify(theme: .dark, query: "Groceries", name: "tag_picker_create_dark")
    }

    @Test("create affordance, sepia") func createSepia() {
        verify(theme: .sepia, query: "Groceries", name: "tag_picker_create_sepia")
    }

    private var labels: [LabelRecord] {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return [
            LabelRecord(id: "travel", name: "Travel", hue: 220, createdAt: now, updatedAt: now),
            LabelRecord(id: "work", name: "Work", hue: 200, createdAt: now, updatedAt: now),
        ]
    }

    private func verify(
        theme: SuperTheme.Identifier,
        query: String,
        name: String,
        function: String = #function
    ) {
        let resolved = SuperTheme.make(theme)
        let view = TodoTagPicker(
            labels: labels,
            selectedIds: .constant(["travel"]),
            onCreate: { _ in nil },
            initialQuery: query
        )
        .padding(18)
        .frame(width: 402, height: 180, alignment: .topLeading)
        .background(resolved.background)
        .superTheme(resolved)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 180)),
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
