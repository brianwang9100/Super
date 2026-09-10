#if canImport(UIKit)
import Core
import SnapshotTesting
import VisualTestSupport
import SwiftUI
import Testing
@testable import Chat

@Suite("MemoryUpdatedPill snapshots", .serialized)
@MainActor
struct MemoryUpdatedPillSnapshotTests {
    init() { SnapshotFontRegistration.ensureRegistered() }
    @Test("collapsed save in light")
    func collapsedSaveLight() {
        verify(
            op: .save, text: "Prefers metric units.",
            initiallyExpanded: false, theme: .vellumLight,
            name: "memory_pill_collapsed_save_light"
        )
    }

    @Test("collapsed save in dark")
    func collapsedSaveDark() {
        verify(
            op: .save, text: "Prefers metric units.",
            initiallyExpanded: false, theme: .vellumDark,
            name: "memory_pill_collapsed_save_dark"
        )
    }

    @Test("expanded save in light")
    func expandedSaveLight() {
        verify(
            op: .save, text: "Prefers metric units.",
            initiallyExpanded: true, theme: .vellumLight,
            name: "memory_pill_expanded_save_light"
        )
    }

    @Test("expanded update in light")
    func expandedUpdateLight() {
        verify(
            op: .update, text: "Prefers SI units.",
            initiallyExpanded: true, theme: .vellumLight,
            name: "memory_pill_expanded_update_light"
        )
    }

    @Test("expanded forget in light")
    func expandedForgetLight() {
        // Forget inputs contain only an ID; synthetic text would hide the production empty-detail state.
        verify(
            op: .forget, text: nil,
            initiallyExpanded: true, theme: .vellumLight,
            name: "memory_pill_expanded_forget_light"
        )
    }

    @Test("dynamic type XXL")
    func xxLargeExpanded() {
        verify(
            op: .save, text: "Prefers metric units.",
            initiallyExpanded: true, theme: .vellumLight,
            dynamicType: .xxLarge,
            name: "memory_pill_expanded_save_light_xxl"
        )
    }

    enum Op: String { case save, update, forget }

    private func verify(
        op: Op,
        text: String?,
        initiallyExpanded: Bool,
        theme: SuperTheme.Identifier,
        dynamicType: DynamicTypeSize = .large,
        name: String,
        function: String = #function
    ) {
        let parametersJSON: String
        switch op {
        case .save:
            parametersJSON = "{\"op\":\"save\",\"text\":\"\(text ?? "")\"}"
        case .update:
            parametersJSON = "{\"op\":\"update\",\"id\":\"mem-1\",\"text\":\"\(text ?? "")\"}"
        case .forget:
            parametersJSON = "{\"op\":\"forget\",\"id\":\"mem-1\"}"
        }
        let call = MessageList.ToolCallItem(
            id: "tc-1",
            toolName: MemoryTool.toolID,
            toolDisplayName: "Memory",
            parametersJSON: parametersJSON,
            resultText: "Memory \(op.rawValue) mem-1: \(text ?? "")",
            status: .success
        )
        let view = MemoryUpdatedPill(call: call, _isExpanded: initiallyExpanded)
            .superTheme(.make(theme))
            .dynamicTypeSize(dynamicType)
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
            .frame(width: 402, height: 120)

        let failure = verifyVisualSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 120)),
            named: name,
            testName: function
        )
        if let failure {
            Issue.record("\(name): \(failure)")
        }
    }
}

#endif
