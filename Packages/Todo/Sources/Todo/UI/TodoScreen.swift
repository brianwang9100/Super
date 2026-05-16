import Core
import GRDBQuery
import SwiftUI

/// Root surface of the Todo applet: the "Tasks" header with state counts,
/// the filter pill, the grouped task list (or empty state), a floating
/// add button, and the toast layer. Task and label data bind reactively
/// via `@Query` so edits from other applets appear without a manual reload.
/// Mirrors `TodoApp` in the Todo design source's `app.jsx`.
public struct TodoScreen: View {
    @Query(ActiveTasksRequest()) private var tasks: [TaskWithLabels]
    @Query(ActiveLabelsRequest()) private var labels: [LabelRecord]

    @State private var viewModel: TodoScreenViewModel
    @State private var filterSheetOpen = false
    @State private var toastDismissTask: Task<Void, Never>?

    @Environment(\.superFontScale) private var fontScale
    @Environment(\.superTheme) private var theme

    public init(viewModel: TodoScreenViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        // Read `draft` directly here so `@Observable` registers the
        // dependency — a computed `Binding` whose getter reads it lazily
        // is not tracked, and the editor sheet would fail to present or
        // dismiss in step with the view model.
        let editorPresented = viewModel.draft != nil
        return ZStack(alignment: .topTrailing) {
            theme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, 110)
                    .padding(.horizontal, 18)
                TodoFilterPill(summary: filterSummary) { filterSheetOpen = true }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                taskList
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            addButton
        }
        .sheet(isPresented: $filterSheetOpen) {
            TodoFilterSheet(
                filter: filterBinding,
                labels: labels
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: Binding(
            get: { editorPresented },
            set: { if !$0 { viewModel.cancelDraft() } }
        )) {
            TodoTaskEditorSheet(
                draft: draftBinding,
                mode: viewModel.draftMode,
                labels: labels,
                onSave: { await viewModel.saveDraft() },
                onCancel: { viewModel.cancelDraft() },
                onDelete: {
                    if let id = viewModel.draft?.id {
                        await viewModel.delete(taskID: id)
                    }
                    viewModel.cancelDraft()
                },
                onCreateLabel: { await viewModel.ensureLabel(name: $0) },
                now: viewModel.now,
                calendar: viewModel.calendar
            )
            .presentationDetents([.large])
        }
        .overlay(alignment: .bottom) { toastLayer }
        .onChange(of: viewModel.toast?.id) { _, id in
            guard let id else { return }
            scheduleToastDismiss(id: id)
        }
        .onDisappear { toastDismissTask?.cancel() }
    }

    // MARK: Header

    private var header: some View {
        let counts = stateCounts
        return VStack(alignment: .leading, spacing: 5) {
            Text("Tasks")
                .font(.system(size: 34 * fontScale, design: .serif))
                .foregroundStyle(theme.ink)
            HStack(spacing: 6) {
                Text("\(counts.open) open").foregroundStyle(theme.inkFaint)
                if counts.done > 0 {
                    Text("·").foregroundStyle(theme.inkMute)
                    Text("\(counts.done) done").foregroundStyle(theme.inkMute)
                }
                if counts.cancelled > 0 {
                    Text("·").foregroundStyle(theme.inkMute)
                    Text("\(counts.cancelled) cancelled").foregroundStyle(theme.inkMute)
                }
            }
            .font(.system(size: 14 * fontScale))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var addButton: some View {
        Button {
            viewModel.beginCreate()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.accentInk)
                // 36×36 mirrors the shell's hamburger button; the top
                // offset aligns it to the same baseline (safe-area top + 4)
                // — `TodoScreen`'s root ignores the safe area, so the inset
                // is applied here as an explicit offset.
                .frame(width: 36, height: 36)
                .background(theme.accent)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .padding(.top, 66)
        .padding(.trailing, 12)
        .accessibilityLabel("Add task")
    }

    // MARK: List

    @ViewBuilder private var taskList: some View {
        if filteredTasks.isEmpty {
            TodoEmptyState()
                .frame(maxWidth: .infinity)
                .padding(.top, 50)
            Spacer(minLength: 0)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(groupedTasks) { group in
                        if let title = group.title {
                            TodoSectionHeader(title: title, count: group.tasks.count)
                        }
                        ForEach(group.tasks) { row in
                            TodoTaskRow(
                                row: row,
                                now: viewModel.now,
                                calendar: viewModel.calendar,
                                onToggleState: { row in Task { await viewModel.cycleState(row) } },
                                onPress: { row in viewModel.beginEdit(row) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 130)
            }
        }
    }

    @ViewBuilder private var toastLayer: some View {
        if let toast = viewModel.toast {
            TodoToast(text: toast.text)
                .padding(.bottom, 100)
                .id(toast.id)
                .transition(.opacity)
        }
    }

    // MARK: Derived state

    /// Tasks after the active filter — the single definition both the
    /// empty-state check and `groupedTasks` derive from.
    private var filteredTasks: [TaskWithLabels] {
        applyFilter(viewModel.filter, to: tasks, now: viewModel.now, calendar: viewModel.calendar)
    }

    private var groupedTasks: [TodoListGroup] {
        groupTasks(filteredTasks, filter: viewModel.filter, now: viewModel.now, calendar: viewModel.calendar)
    }

    private var stateCounts: (open: Int, done: Int, cancelled: Int) {
        var open = 0, done = 0, cancelled = 0
        for row in tasks {
            switch row.task.state {
            case .open:      open += 1
            case .done:      done += 1
            case .cancelled: cancelled += 1
            }
        }
        return (open, done, cancelled)
    }

    private var filterSummary: String {
        describe(viewModel.filter, labelLookup: Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) }))
    }

    // MARK: Bindings

    private var filterBinding: Binding<TodoFilter> {
        Binding(get: { viewModel.filter }, set: { viewModel.filter = $0 })
    }

    private var draftBinding: Binding<TaskDraft> {
        Binding(get: { viewModel.draft ?? .empty }, set: { viewModel.draft = $0 })
    }

    private func scheduleToastDismiss(id: String) {
        toastDismissTask?.cancel()
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled, viewModel.toast?.id == id else { return }
            viewModel.dismissToast()
        }
    }
}
