import GRDBQuery
import SwiftUI

/// Per-tool config pane reached from the gear affordance on the Memory
/// row in `SettingsToolsPane`.
///
/// Lets the user review what the LLM (Large Language Model) has saved
/// about them, edit individual entries inline, swipe-delete a row, or
/// clear everything. Memories are bound reactively via GRDBQuery `@Query`
/// so a write from the `memory` tool (mid-conversation, in a sibling
/// chat surface) repaints the pane without an explicit refresh — per
/// CLAUDE.md's reactive-binding rule for tables mutated outside the
/// view.
struct SettingsMemoryPane: View {
    @Bindable var viewModel: SettingsViewModel

    /// Live snapshot of every persisted memory, oldest first. Falls
    /// back to `MemoriesRequest.defaultValue` (empty) when the host
    /// didn't wire a `DatabaseContext` — i.e. snapshot tests and
    /// previews still render the empty / populated states under
    /// `_setSnapshotMemories(...)`.
    @Query(MemoriesRequest()) private var memories: [MemoryRecord]

    @State private var pendingClearAll: Bool = false
    @State private var editingId: String?
    @State private var draft: String = ""
    @FocusState private var focusedId: String?

    @Environment(\.superTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preamble
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            if memories.isEmpty {
                emptyState
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
            } else {
                SettingsGroup {
                    ForEach(Array(memories.enumerated()), id: \.element.id) { index, memory in
                        memoryRow(memory: memory, isLast: index == memories.count - 1)
                    }
                }

                Button(role: .destructive) {
                    pendingClearAll = true
                } label: {
                    Text("Clear All")
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(theme.errorAccent)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 24)
        .alert("Clear all memories?", isPresented: $pendingClearAll) {
            Button("Clear All", role: .destructive) {
                Task { await viewModel.clearAllMemories() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("I'll forget everything you've shared. Future conversations will start fresh.")
        }
    }

    private var preamble: some View {
        Text("Memory lets me remember things across conversations. I'll add entries automatically as we talk; you can edit or delete them here.")
            .font(.system(.caption))
            .foregroundStyle(theme.inkFaint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func memoryRow(memory: MemoryRecord, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if editingId == memory.id {
                // Commit only on focus loss, matching SettingsPromptPane's
                // pattern. An earlier `.onSubmit` paired with the
                // `.onChange` below double-fired on Return (the submit
                // handler sets `focusedId = nil`, which re-triggers
                // onChange), spawning two updateMemory tasks per
                // Return-keypress. `axis: .vertical` already treats
                // Return as a newline, so dropping onSubmit costs no
                // UX — the user dismisses the keyboard by tapping
                // outside.
                TextField("Memory text", text: $draft, axis: .vertical)
                    .font(.system(.subheadline))
                    .foregroundStyle(theme.ink)
                    .focused($focusedId, equals: memory.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: focusedId) { _, newValue in
                        if newValue != memory.id { commitEdit(for: memory) }
                    }
            } else {
                Text(memory.text)
                    .font(.system(.subheadline))
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { beginEditing(memory: memory) }
            }

            Button {
                Task { await viewModel.deleteMemory(id: memory.id) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(theme.inkFaint)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete memory")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(theme.borderFaint)
                    .frame(height: 1)
                    .padding(.leading, 16)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No memories yet")
                .font(.system(.subheadline))
                .foregroundStyle(theme.inkSoft)
            Text("Tell me a preference (\u{201C}I prefer metric units\u{201D}) and I'll save it here.")
                .font(.system(.caption))
                .foregroundStyle(theme.inkFaint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func beginEditing(memory: MemoryRecord) {
        draft = memory.text
        editingId = memory.id
        focusedId = memory.id
    }

    private func commitEdit(for memory: MemoryRecord) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editingId = nil
        focusedId = nil
        guard !trimmed.isEmpty, trimmed != memory.text else { return }
        Task { await viewModel.updateMemory(id: memory.id, text: trimmed) }
    }
}
