import Core
import SwiftUI

/// Create / edit sheet for a single task: title, notes, priority, due date,
/// labels — plus a state row and delete button in edit mode. Mirrors
/// `TaskModal` in the Todo design source's `sheets.jsx`.
///
/// Each editable field binds through its *own* two-way binding rather than
/// one shared `Binding<TaskDraft>`. That isolation is load-bearing: the two
/// multiline `TextField`s commit their text late, and a single whole-draft
/// binding let such a late commit clobber a sibling field (e.g. revert a
/// just-changed priority). Per-field bindings write only their own field.
struct TodoTaskEditorSheet: View {
    @Binding var title: String
    @Binding var notes: String
    @Binding var priority: TaskPriority
    @Binding var dueAt: Date?
    @Binding var labelIds: [String]
    @Binding var state: TaskState
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
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    private var titleIsBlank: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        // Presents at `.large` with the grabber hidden, so without this the nav
        // bar would hug the sheet's rounded top corner — the margin gives the
        // ✕ / ✓ room to breathe (the `.fitsContent` nav-bar inset stays 0). Same
        // compensation the Bible note editor applies.
        .padding(.top, 14)
        .background(theme.background)
    }

    /// Shared sheet nav bar: leading neutral-glass cancel (✕), centered title,
    /// and the accent-tinted call-to-action **save** (✓) in the trailing slot —
    /// the same close/save pairing as the Bible note editor, with the matching
    /// `.fitsContent` zero top inset (the grabber is hidden, so there's nothing
    /// to clear; the body's top padding handles the rounded-corner breathing
    /// room). Replaces the old bespoke tinted-disc title bar.
    private var titleBar: some View {
        SheetNavBar(
            title: mode == .create ? "New task" : "Edit task",
            sizing: .fitsContent,
            onClose: onCancel
        ) {
            saveButton
        }
    }

    /// ✓ that commits the draft, hosted in the nav bar's trailing slot;
    /// disabled + dimmed until the title has non-whitespace content. Accent
    /// call-to-action glass, mirroring `NoteEditor`'s save button.
    private var saveButton: some View {
        Button {
            Task { await onSave() }
        } label: {
            Image(systemName: "checkmark")
                .font(typography.font(size: 16, weight: .semibold))
                .foregroundStyle(titleIsBlank ? theme.inkMute : theme.accentInk)
                .frame(width: 44, height: 44)
                .superGlassCTAButton(in: Circle())
                .opacity(titleIsBlank ? 0.6 : 1)
        }
        .buttonStyle(GlassHapticButtonStyle(.primary))
        .disabled(titleIsBlank)
        .accessibilityLabel(mode == .create ? "Add task" : "Save task")
    }

    private var textFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("What needs to happen?", text: $title, axis: .vertical)
                // Brand italic display face (EB Garamond Italic); `display`
                // folds the app font-scale slider in, Dynamic-Type inert.
                .font(typography.display(22, relativeTo: nil))
                .foregroundStyle(theme.ink)
            TextField("Notes (optional)", text: $notes, axis: .vertical)
                .font(typography.font(size: 15))
                .foregroundStyle(theme.inkSoft)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(typography.font(size: 13, weight: .medium, design: .monospaced))
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
                ForEach(TaskPriority.allCases, id: \.self) { option in
                    let selected = priority == option
                    Button {
                        priority = option
                    } label: {
                        VStack(spacing: 3) {
                            Circle()
                                .fill(OKLCH(0.62, 0.14, option.hue).color)
                                .frame(width: 7, height: 7)
                            Text(option.displayName)
                                .font(typography.font(size: 15, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(selected ? OKLCH(0.4, 0.1, option.hue).color : theme.inkSoft)
                        .modifier(SelectorChipSurface(
                            shape: RoundedRectangle(cornerRadius: 10),
                            selected: selected,
                            selectedFill: OKLCH(0.94, 0.035, option.hue).color,
                            selectedBorder: OKLCH(0.62, 0.14, option.hue).color
                        ))
                    }
                    .buttonStyle(GlassHapticButtonStyle(.selection, scale: true))
                }
            }
        }
    }

    private var dueField: some View {
        field("Due · optional") {
            VStack(alignment: .leading, spacing: 8) {
                FlowLayout(spacing: 6) {
                    duePill("No date", selected: dueAt == nil) { selectPreset(nil) }
                    duePill("Today", selected: isSameDay(dueAt, offsetDays: 0)) {
                        selectPreset(dayOffset(0))
                    }
                    duePill("Tomorrow", selected: isSameDay(dueAt, offsetDays: 1)) {
                        selectPreset(dayOffset(1))
                    }
                    duePill("This week", selected: isSameDay(dueAt, offsetDays: 7)) {
                        selectPreset(dayOffset(7))
                    }
                    duePill(pickPillTitle, selected: isCustomDate) { showingDatePicker = true }
                }
                if showingDatePicker {
                    DatePicker(
                        "Due date",
                        selection: Binding(get: { dueAt ?? now }, set: { dueAt = $0 }),
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
                .font(typography.font(size: 15, weight: .medium))
                .foregroundStyle(selected ? theme.accent : theme.inkSoft)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .modifier(SelectorChipSurface(
                    shape: Capsule(),
                    selected: selected,
                    selectedFill: theme.accentSoft,
                    selectedBorder: theme.accent
                ))
        }
        .buttonStyle(GlassHapticButtonStyle(.selection, scale: true))
    }

    private var labelsField: some View {
        field("Labels · \(labelIds.count) selected") {
            TodoTagPicker(labels: labels, selectedIds: $labelIds, onCreate: onCreateLabel)
        }
    }

    private var stateField: some View {
        field("State") {
            HStack(spacing: 6) {
                ForEach(TaskState.allCases, id: \.self) { option in
                    let selected = state == option
                    Button {
                        state = option
                    } label: {
                        Text(option.displayName)
                            .font(typography.font(size: 15, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundStyle(selected ? theme.accent : theme.inkSoft)
                            .modifier(SelectorChipSurface(
                                shape: RoundedRectangle(cornerRadius: 10),
                                selected: selected,
                                selectedFill: theme.accentSoft,
                                selectedBorder: theme.accent
                            ))
                    }
                    .buttonStyle(GlassHapticButtonStyle(.selection, scale: true))
                }
            }
        }
    }

    private var deleteButton: some View {
        Button {
            Task { await onDelete() }
        } label: {
            Text("Delete task")
                .font(typography.font(size: 15, weight: .medium))
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
        dueAt = date
        showingDatePicker = false
    }

    /// The "Pick…" pill's label: the chosen date once a custom (non-preset)
    /// due date is set, otherwise the neutral "Pick…" prompt.
    private var pickPillTitle: String {
        guard isCustomDate, let due = dueAt else { return "Pick…" }
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
        guard dueAt != nil else { return false }
        return !isSameDay(dueAt, offsetDays: 0)
            && !isSameDay(dueAt, offsetDays: 1)
            && !isSameDay(dueAt, offsetDays: 7)
    }
}

/// Surface for a Todo selector chip (priority / due / state). When picked it
/// keeps a solid accent- or hue-soft fill + matching border so the selection
/// stays loud; otherwise it swaps the old neutral raised fill + faint stroke
/// for Liquid Glass, so the unselected segments frost like the rest of the
/// app's chrome. The chip is the whole tap target, so the unselected branch
/// uses `superGlassButton` (which re-asserts the shape's hit region).
///
/// Glass is **inert** here (`interactive: false`): these chips sit in tight
/// rows (3 priorities, 3 states, 5 due pills), and interactive glass
/// glow-flickers as each shape springs back on release in a dense cluster —
/// the same reason the Bible verse action sheet opts out. The press feedback
/// is supplied instead by ``SuperPressButtonStyle`` on the hosting button.
private struct SelectorChipSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let selected: Bool
    let selectedFill: Color
    let selectedBorder: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if selected {
            content
                .background(selectedFill)
                .overlay(shape.strokeBorder(selectedBorder, lineWidth: 1))
                .clipShape(shape)
        } else {
            content.superGlassButton(in: shape, interactive: false)
        }
    }
}
