import GRDBQuery
import SwiftUI

struct SettingsMemoryPane: View {
    @Bindable var viewModel: SettingsViewModel

    @Query(MemoriesRequest()) private var memories: [MemoryRecord]

    @State private var pendingClearAll: Bool = false
    @State private var editingId: String?
    @State private var draft: String = ""
    @FocusState private var focusedId: String?

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

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
                        .font(typography.font(.subheadline, weight: .medium))
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
            .font(typography.font(.caption))
            .foregroundStyle(theme.inkFaint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func memoryRow(memory: MemoryRecord, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if editingId == memory.id {
                // Commit on focus loss only: adding onSubmit would double-write when Return clears focus.
                TextField("Memory text", text: $draft, axis: .vertical)
                    .font(typography.font(.subheadline))
                    .foregroundStyle(theme.ink)
                    .focused($focusedId, equals: memory.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: focusedId) { _, newValue in
                        if newValue != memory.id { commitEdit(for: memory) }
                    }
            } else {
                Text(memory.text)
                    .font(typography.font(.subheadline))
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
                    .font(typography.font(size: 14, weight: .regular))
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
                .font(typography.font(.subheadline))
                .foregroundStyle(theme.inkSoft)
            Text("Tell me a preference (\u{201C}I prefer metric units\u{201D}) and I'll save it here.")
                .font(typography.font(.caption))
                .foregroundStyle(theme.inkFaint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func beginEditing(memory: MemoryRecord) {
        // Commit A before replacing its draft with B's text when focus moves directly between rows.
        if let priorId = editingId, priorId != memory.id,
           let prior = memories.first(where: { $0.id == priorId }) {
            commitEdit(for: prior)
        }
        draft = memory.text
        editingId = memory.id
        focusedId = memory.id
    }

    private func commitEdit(for memory: MemoryRecord) {
        let decision = Self.decideCommit(
            editingId: editingId,
            target: memory,
            draft: draft
        )
        if decision.clearsEditState {
            editingId = nil
            focusedId = nil
        }
        if let update = decision.update {
            Task { await viewModel.updateMemory(id: update.id, text: update.text) }
        }
    }

    /// Ignore stale focus callbacks so a draft for the next row cannot overwrite the previous row.
    nonisolated static func decideCommit(
        editingId: String?,
        target: MemoryRecord,
        draft: String
    ) -> CommitDecision {
        guard editingId == target.id else {
            return CommitDecision(clearsEditState: false, update: nil)
        }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == target.text {
            return CommitDecision(clearsEditState: true, update: nil)
        }
        return CommitDecision(
            clearsEditState: true,
            update: PendingUpdate(id: target.id, text: trimmed)
        )
    }

    struct CommitDecision: Equatable {
        let clearsEditState: Bool
        let update: PendingUpdate?
    }

    struct PendingUpdate: Equatable {
        let id: String
        let text: String
    }
}
