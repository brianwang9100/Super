#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Bible

/// Snapshots of `NoteEditor` — the create / edit modal. Variants cover the
/// empty create state (Save disabled, placeholder shown) across the three
/// themes, the prefilled edit state (Save enabled, Delete section present)
/// across the three themes, and a Dynamic Type XXL edit pass. The
/// destructive `.confirmationDialog` is system chrome and is not
/// snapshotted, matching `AnnotationBlock`'s delete-confirmation precedent.
@Suite("NoteEditor snapshots")
@MainActor
struct NoteEditorSnapshotTests {
    /// Register Core's bundled brand fonts so the migrated JetBrains Mono /
    /// Instrument Serif chrome faces resolve instead of baking the system
    /// fallback, and so this suite stays order-independent (registration is
    /// process-global; see `SnapshotFontRegistration`).
    init() { SnapshotFontRegistration.ensureRegistered() }

    private static let citation = "John 3:16–18"

    private static let editBody = "This is the hinge of the whole gospel. \"God so loved the world\" — the love comes first, before anything is asked of us. Come back here when belief starts to feel like effort."

    @Test("empty create state renders in the light theme")
    func createLight() {
        verify(theme: .light, mode: .create, initialText: "", name: "create_light")
    }

    @Test("empty create state renders in the dark theme")
    func createDark() {
        verify(theme: .dark, mode: .create, initialText: "", name: "create_dark")
    }

    @Test("empty create state renders in the sepia theme")
    func createSepia() {
        verify(theme: .sepia, mode: .create, initialText: "", name: "create_sepia")
    }

    @Test("populated create state enables Save without a Delete section")
    func createPopulatedLight() {
        // Create mode with text typed: Save flips to enabled (accent) and
        // no Delete section appears (that's edit-only). Distinct from both
        // the empty-create and the edit states.
        verify(theme: .light, mode: .create, initialText: Self.editBody, name: "create_populated_light")
    }

    @Test("populated create state renders in the dark theme")
    func createPopulatedDark() {
        verify(theme: .dark, mode: .create, initialText: Self.editBody, name: "create_populated_dark")
    }

    @Test("populated create state renders in the sepia theme")
    func createPopulatedSepia() {
        verify(theme: .sepia, mode: .create, initialText: Self.editBody, name: "create_populated_sepia")
    }

    @Test("prefilled edit state renders in the light theme")
    func editLight() {
        verify(theme: .light, mode: .edit, initialText: Self.editBody, name: "edit_light")
    }

    @Test("prefilled edit state renders in the dark theme")
    func editDark() {
        verify(theme: .dark, mode: .edit, initialText: Self.editBody, name: "edit_dark")
    }

    @Test("prefilled edit state renders in the sepia theme")
    func editSepia() {
        verify(theme: .sepia, mode: .edit, initialText: Self.editBody, name: "edit_sepia")
    }

    @Test("prefilled edit state holds shape at Dynamic Type XXL")
    func editLightXXL() {
        verify(theme: .light, mode: .edit, initialText: Self.editBody,
               height: 640, dynamicType: .xxLarge, name: "edit_light_xxl")
    }

    private func verify(
        theme themeID: SuperTheme.Identifier,
        mode: NoteEditor.Mode,
        initialText: String,
        height: CGFloat = 480,
        dynamicType: DynamicTypeSize = .large,
        name: String,
        function: String = #function
    ) {
        let theme = SuperTheme.make(themeID)
        let view = ZStack {
            theme.background
            NoteEditor(
                citation: Self.citation,
                mode: mode,
                initialText: initialText,
                onSave: { _ in },
                onCancel: {},
                onDelete: {}
            )
        }
        .frame(width: 393, height: height)
        .superTheme(theme)
        .dynamicTypeSize(dynamicType)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: height)),
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
