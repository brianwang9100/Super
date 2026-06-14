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
///
/// `.serialized` matches every sibling Todo snapshot suite: image snapshots
/// touch process-global recording + font-registration state, so the suites
/// run serially to keep that setup deterministic — not to paper over a race.
@Suite("TodoTagPicker snapshots", .serialized)
@MainActor
struct TodoTagPickerSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    /// Empty query: the glass input field with one selected chip plus the
    /// frosted suggestion chips for the unselected pool.
    @Test("suggestions, light") func suggestionsLight() {
        verify(theme: .vellumLight, query: "", name: "tag_picker_suggestions_light")
    }

    @Test("suggestions, dark") func suggestionsDark() {
        verify(theme: .vellumDark, query: "", name: "tag_picker_suggestions_dark")
    }

    /// Typed query with no exact match: the accent "＋ Create" call-to-action
    /// glass, across Vellum light and dark.
    @Test("create affordance, light") func createLight() {
        verify(theme: .vellumLight, query: "Groceries", name: "tag_picker_create_light")
    }

    @Test("create affordance, dark") func createDark() {
        verify(theme: .vellumDark, query: "Groceries", name: "tag_picker_create_dark")
    }

    /// Chips reflow through `FlowLayout`, so the larger Dynamic Type size
    /// exercises the wrapping of the selected chip + suggestion pool.
    @Test("suggestions, Dynamic Type XXL") func suggestionsXXL() {
        verify(
            theme: .vellumLight,
            query: "",
            dynamicType: .xxLarge,
            height: 240,
            name: "tag_picker_suggestions_light_xxl"
        )
    }

    /// The "＋ Create" row carries user-length text (the typed query), so the
    /// larger Dynamic Type size exercises its reflow.
    @Test("create affordance, Dynamic Type XXL") func createXXL() {
        verify(
            theme: .vellumLight,
            query: "Groceries",
            dynamicType: .xxLarge,
            height: 240,
            name: "tag_picker_create_light_xxl"
        )
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
        dynamicType: DynamicTypeSize = .large,
        height: CGFloat = 180,
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
        .frame(width: 402, height: height, alignment: .topLeading)
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
