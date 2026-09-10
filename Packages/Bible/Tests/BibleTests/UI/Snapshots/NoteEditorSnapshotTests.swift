#if canImport(UIKit)
import Core
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Bible

/// Native delete confirmation chrome is outside this fixed-layout content capture.
@Suite("NoteEditor snapshots", .serialized)
@MainActor
struct NoteEditorSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }

    private static let citation = "John 3:16–18"

    private static let editBody = "This is the hinge of the whole gospel. \"God so loved the world\" — the love comes first, before anything is asked of us. Come back here when belief starts to feel like effort."

    @Test("empty create state renders in the light theme")
    func createLight() {
        verify(theme: .vellumLight, mode: .create, initialText: "", name: "create_light")
    }

    @Test("empty create state renders in the dark theme")
    func createDark() {
        verify(theme: .vellumDark, mode: .create, initialText: "", name: "create_dark")
    }

    @Test("populated create state enables Save without a Delete section")
    func createPopulatedLight() {
        verify(theme: .vellumLight, mode: .create, initialText: Self.editBody, name: "create_populated_light")
    }

    @Test("populated create state renders in the dark theme")
    func createPopulatedDark() {
        verify(theme: .vellumDark, mode: .create, initialText: Self.editBody, name: "create_populated_dark")
    }

    @Test("prefilled edit state renders in the light theme")
    func editLight() {
        verify(theme: .vellumLight, mode: .edit, initialText: Self.editBody, name: "edit_light")
    }

    @Test("prefilled edit state renders in the dark theme")
    func editDark() {
        verify(theme: .vellumDark, mode: .edit, initialText: Self.editBody, name: "edit_dark")
    }

    @Test("prefilled edit state holds shape at Dynamic Type XXL")
    func editLightXXL() {
        verify(theme: .vellumLight, mode: .edit, initialText: Self.editBody,
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

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: height)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}
#endif
