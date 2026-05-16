import Core
import SwiftUI

/// Create / edit sheet for a single task: title, notes, priority, due date,
/// labels — plus a state row and delete button in edit mode. Mirrors
/// `TaskModal` in the Todo design source's `sheets.jsx`. Binds directly to
/// the view model's draft.
struct TodoTaskEditorSheet: View {
    @Binding var draft: TaskDraft
    let mode: TodoScreenViewModel.DraftMode
    let labels: [LabelRecord]
    let onSave: () async -> Void
    let onCancel: () -> Void
    let onDelete: () async -> Void
    let onCreateLabel: (String) async -> String?
    /// "Now" for the due-date pills' day arithmetic. Injected (rather than
    /// reading `Date()`) so the pill highlight logic is deterministic and
    /// testable, per `AGENTS.md` §Testing.
    let now: Date
    /// Calendar for the due-date pills' day arithmetic. Injected so "Today"
    /// / "Tomorrow" resolve to the same day boundaries the screen's grouping
    /// uses — a mismatch would land a `dueAt` the list classifies elsewhere.
    let calendar: Calendar

    @State private var showingDatePicker = false
    @Environment(\.superFontScale) private var fontScale
    @Environment(\.superTheme) private var theme

    private var titleIsBlank: Bool {
        draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    textFields
                    priorityField
                    dueField
                    labelsField
                    if mode == .edit {
                        stateField
                        deleteButton
                    }
                }
            }
        }
        .background(theme.background)
    }

    private var titleBar: some View {
        HStack {
            circleButton(
                systemName: "xmark",
                tint: Self.cancelRed,
                accessibilityLabel: "Cancel",
                action: onCancel
            )
            Spacer()
            Text(mode == .create ? "New task" : "Edit task")
                .font(.system(size: 17 * fontScale, weight: .semibold))
                .foregroundStyle(theme.ink)
            Spacer()
            circleButton(
                systemName: "checkmark",
                tint: titleIsBlank ? theme.inkMute : theme.accent,
                accessibilityLabel: mode == .create ? "Add task" : "Save task"
            ) {
                Task { await onSave() }
            }
            .disabled(titleIsBlank)
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    /// A 32pt circular nav action — a tinted disc with a white glyph.
    private func circleButton(
        systemName: String,
        tint: Color,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(tint)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Warm red for the cancel action — the design's `oklch(0.55 0.16 25)`.
    private static let cancelRed = OKLCH(0.55, 0.16, 25).color

    private var textFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("What needs to happen?", text: $draft.title, axis: .vertical)
                .font(.system(size: 22 * fontScale, design: .serif))
                .foregroundStyle(theme.ink)
            TextField("Notes (optional)", text: $draft.notes, axis: .vertical)
                .font(.system(size: 15 * fontScale))
                .foregroundStyle(theme.inkSoft)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 13 * fontScale, weight: .medium, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(theme.inkFaint)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.borderFaint).frame(height: 0.5)
        }
    }

    private var priorityField: some View {
        field("Priority · required") {
            HStack(spacing: 6) {
                ForEach(TaskPriority.allCases, id: \.self) { priority in
                    let selected = draft.priority == priority
                    Button {
                        draft.priority = priority
                    } label: {
                        VStack(spacing: 3) {
                            Circle()
                                .fill(OKLCH(0.62, 0.14, priority.hue).color)
                                .frame(width: 7, height: 7)
                            Text(priority.displayName)
                                .font(.system(size: 15 * fontScale, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(selected ? OKLCH(0.4, 0.1, priority.hue).color : theme.inkSoft)
                        .background(selected ? OKLCH(0.94, 0.035, priority.hue).color : theme.backgroundRaised)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10).strokeBorder(
                                selected ? OKLCH(0.62, 0.14, priority.hue).color : theme.borderFaint,
                                lineWidth: 1
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var dueField: some View {
        field("Due · optional") {
            VStack(alignment: .leading, spacing: 8) {
                FlowLayout(spacing: 6) {
                    duePill("No date", selected: draft.dueAt == nil) { selectPreset(nil) }
                    duePill("Today", selected: isSameDay(draft.dueAt, offsetDays: 0)) {
                        selectPreset(dayOffset(0))
                    }
                    duePill("Tomorrow", selected: isSameDay(draft.dueAt, offsetDays: 1)) {
                        selectPreset(dayOffset(1))
                    }
                    duePill("This week", selected: isSameDay(draft.dueAt, offsetDays: 7)) {
                        selectPreset(dayOffset(7))
                    }
                    duePill(pickPillTitle, selected: isCustomDate) { showingDatePicker = true }
                }
                if showingDatePicker {
                    DatePicker(
                        "Due date",
                        selection: Binding(get: { draft.dueAt ?? now }, set: { draft.dueAt = $0 }),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                }
            }
        }
    }

    private func duePill(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15 * fontScale, weight: .medium))
                .foregroundStyle(selected ? theme.accent : theme.inkSoft)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? theme.accentSoft : theme.backgroundRaised)
                .overlay(Capsule().strokeBorder(selected ? theme.accent : theme.borderFaint, lineWidth: 1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var labelsField: some View {
        field("Labels · \(draft.labelIds.count) selected") {
            TodoTagPicker(labels: labels, selectedIds: $draft.labelIds, onCreate: onCreateLabel)
        }
    }

    private var stateField: some View {
        field("State") {
            HStack(spacing: 6) {
                ForEach(TaskState.allCases, id: \.self) { state in
                    let selected = draft.state == state
                    Button {
                        draft.state = state
                    } label: {
                        Text(state.displayName)
                            .font(.system(size: 15 * fontScale, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundStyle(selected ? theme.accent : theme.inkSoft)
                            .background(selected ? theme.accentSoft : theme.backgroundRaised)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10).strokeBorder(
                                    selected ? theme.accent : theme.borderFaint, lineWidth: 1
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var deleteButton: some View {
        Button {
            Task { await onDelete() }
        } label: {
            Text("Delete task")
                .font(.system(size: 15 * fontScale, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .foregroundStyle(OKLCH(0.5, 0.16, 25).color)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(OKLCH(0.85, 0.05, 25).color, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .padding(18)
    }

    // MARK: Due-date helpers

    /// Applies a preset due date (or clears it) and collapses the custom
    /// date picker — the presets and the graphical picker are mutually
    /// exclusive ways to set the date, so choosing a preset dismisses the
    /// picker and drops "Pick…" back to its neutral prompt.
    private func selectPreset(_ date: Date?) {
        draft.dueAt = date
        showingDatePicker = false
    }

    /// The "Pick…" pill's label: the chosen date once a custom (non-preset)
    /// due date is set, otherwise the neutral "Pick…" prompt.
    private var pickPillTitle: String {
        guard isCustomDate, let due = draft.dueAt else { return "Pick…" }
        return due.formatted(.dateTime.month(.abbreviated).day())
    }

    private func dayOffset(_ days: Int) -> Date {
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: days, to: start) ?? start
    }

    private func isSameDay(_ date: Date?, offsetDays: Int) -> Bool {
        guard let date else { return false }
        return calendar.isDate(date, inSameDayAs: dayOffset(offsetDays))
    }

    /// True when a due date is set that none of the preset pills (Today,
    /// Tomorrow, This week) own — only then does "Pick…" light up.
    private var isCustomDate: Bool {
        guard draft.dueAt != nil else { return false }
        return !isSameDay(draft.dueAt, offsetDays: 0)
            && !isSameDay(draft.dueAt, offsetDays: 1)
            && !isSameDay(draft.dueAt, offsetDays: 7)
    }
}
