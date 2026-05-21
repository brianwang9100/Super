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
        verify(
            op: .forget, text: "Vegetarian.",
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
        text: String,
        initiallyExpanded: Bool,
        theme: SuperTheme.Identifier,
        dynamicType: DynamicTypeSize = .large,
        name: String,
        function: String = #function
    ) {
        let call = MessageList.ToolCallItem(
            id: "tc-1",
            toolName: MemoryTool.toolID,
            parametersJSON: "{\"op\":\"\(op.rawValue)\",\"text\":\"\(text)\"}",
            resultText: "Saved memory mem-1: \(text)",
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
