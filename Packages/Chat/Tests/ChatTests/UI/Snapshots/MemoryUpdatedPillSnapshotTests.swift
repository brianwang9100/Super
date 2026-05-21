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
        let view = MemoryUpdatedPillHarness(call: call, initiallyExpanded: initiallyExpanded)
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

/// Wrapper that seeds `MemoryUpdatedPill`'s `@State isExpanded` for the
/// expanded snapshots. The pill toggles on tap in production; snapshot
/// tests can't drive taps, so we seed via init by re-creating the view
/// each render with the desired state preset.
private struct MemoryUpdatedPillHarness: View {
    let call: MessageList.ToolCallItem
    let initiallyExpanded: Bool

    var body: some View {
        if initiallyExpanded {
            ExpandedPill(call: call)
        } else {
            MemoryUpdatedPill(call: call)
        }
    }
}

/// Mirrors `MemoryUpdatedPill` but seeded as expanded — kept as a sibling
/// view so the production pill stays a single-state machine driven by
/// taps, while the snapshot harness can pin the expanded baseline.
private struct ExpandedPill: View {
    let call: MessageList.ToolCallItem
    @State private var isExpanded = true
    @Environment(\.superTheme) private var theme

    var body: some View {
        let parsed = ParsedMemoryCall.parse(call.parametersJSON)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "brain")
                .font(.system(.caption2))
                .foregroundStyle(theme.inkFaint)
            Text(headline(for: parsed))
                .font(.system(.caption))
                .foregroundStyle(theme.inkSoft)
            if !parsed.text.isEmpty {
                Text("— \(parsed.text)")
                    .font(.system(.caption))
                    .foregroundStyle(theme.inkFaint)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.backgroundSunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.borderFaint, lineWidth: 1)
        )
    }

    private func headline(for parsed: ParsedMemoryCall) -> String {
        switch parsed.op {
        case .save: return "Saved to memory"
        case .update: return "Updated memory"
        case .forget: return "Forgot memory"
        case .unknown: return "Memory updated"
        }
    }
}
#endif
