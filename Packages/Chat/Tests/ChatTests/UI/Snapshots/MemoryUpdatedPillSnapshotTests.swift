#if canImport(UIKit)
import Core
import SnapshotTesting
import SwiftUI
import Testing
@testable import Chat

/// Snapshots for `MemoryUpdatedPill` covering the three save / update /
/// forget headlines and the collapsed / expanded toggle. Collapsed pins
/// the chip-only shape; expanded pins the inline detail line ("Saved
/// memory — Prefers metric units."). Dark + sepia variants are recorded
/// once on the populated `.save` case since the chrome is shared across
/// ops.
///
/// `.serialized` — snapshot baselines are read/written per-test against
/// the same on-disk `__Snapshots__/MemoryUpdatedPillSnapshotTests/`
/// directory. Parallel execution races on the PNG files (TOCTOU), not on
/// any async behavior in the code under test — serialization is the right
/// tool. Matches every other snapshot suite in this directory; the
/// codebase-wide convention is intentional, not a smell to fix per-file
/// per AGENTS.md §Testing.2.
///
/// Reduce Motion is not recorded as a separate variant: the pill toggles
/// `isExpanded` via a plain `Button` action with no `withAnimation` and
/// no `.animation(...)` modifier, so the steady-state collapsed and
/// expanded frames are pixel-identical regardless of the
/// `accessibilityReduceMotion` env value. Same documented gap as
/// `CompactionBannerSnapshotTests` (lines 56–65).
@Suite("MemoryUpdatedPill snapshots", .serialized)
@MainActor
struct MemoryUpdatedPillSnapshotTests {
    /// Register Core's bundled brand fonts before any render so this suite
    /// is order-independent in the shared test process (the xctest host never
    /// runs the app's font registration). See SnapshotFontRegistration.
    init() { SnapshotFontRegistration.ensureRegistered() }
    @Test("collapsed save in light")
    func collapsedSaveLight() {
        verify(
            op: .save, text: "Prefers metric units.",
            initiallyExpanded: false, theme: .light,
            name: "memory_pill_collapsed_save_light"
        )
    }

    @Test("collapsed save in dark")
    func collapsedSaveDark() {
        verify(
            op: .save, text: "Prefers metric units.",
            initiallyExpanded: false, theme: .dark,
            name: "memory_pill_collapsed_save_dark"
        )
    }

    @Test("collapsed save in sepia")
    func collapsedSaveSepia() {
        verify(
            op: .save, text: "Prefers metric units.",
            initiallyExpanded: false, theme: .sepia,
            name: "memory_pill_collapsed_save_sepia"
        )
    }

    @Test("expanded save in light")
    func expandedSaveLight() {
        verify(
            op: .save, text: "Prefers metric units.",
            initiallyExpanded: true, theme: .light,
            name: "memory_pill_expanded_save_light"
        )
    }

    @Test("expanded update in light")
    func expandedUpdateLight() {
        verify(
            op: .update, text: "Prefers SI units.",
            initiallyExpanded: true, theme: .light,
            name: "memory_pill_expanded_update_light"
        )
    }

    @Test("expanded forget in light")
    func expandedForgetLight() {
        // Production `forget` tool calls only carry `id` (no `text`),
        // so the parametersJSON the pill parses never has text to show
        // even in the expanded state — verify renders "Forgot memory"
        // alone. Earlier this test passed a synthetic `text` field the
        // LLM would never produce, masking the production rendering.
        verify(
            op: .forget, text: nil,
            initiallyExpanded: true, theme: .light,
            name: "memory_pill_expanded_forget_light"
        )
    }

    @Test("dynamic type XXL")
    func xxLargeExpanded() {
        verify(
            op: .save, text: "Prefers metric units.",
            initiallyExpanded: true, theme: .light,
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
        // Mirror the shape of the JSON the LLM actually sends: `forget`
        // carries only `id`; `save` / `update` carry `text` (and `id`
        // only on update). Building the parameters payload here keeps
        // the test fixture honest against production.
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
        // Seed `@State isExpanded` via the underscore-prefixed test seam
        // so the snapshot pins the actual production view, not a hand-
        // rolled mirror — the previous local `ExpandedPill` could
        // silently drift from the real layout on any future tweak.
        let view = MemoryUpdatedPill(call: call, _isExpanded: initiallyExpanded)
            .superTheme(.make(theme))
            .dynamicTypeSize(dynamicType)
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
            .frame(width: 402, height: 120)

        let failure = verifySnapshot(
            of: view,
            as: .image(layout: .fixed(width: 402, height: 120)),
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
