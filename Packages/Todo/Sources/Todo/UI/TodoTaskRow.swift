import Core
import SwiftUI

/// One task row: a left priority stripe, the state box, the title, label
/// chips, and an optional due-date badge. Tapping the row opens the editor
/// (`onPress`); tapping the state box toggles open↔done (`onToggleState`).
/// `now` and `calendar` are injected so the "Today" / "Tomorrow" badge
/// stays deterministic under snapshot tests. Mirrors `TaskCard` (variant B)
/// in the Todo design source's `components.jsx`.
public struct TodoTaskRow: View {
    public let row: TaskWithLabels
    public let now: Date
    public let calendar: Calendar
    public let onToggleState: (TaskWithLabels) -> Void
    public let onPress: (TaskWithLabels) -> Void

    @Environment(\.superTheme) private var theme

    public init(
        row: TaskWithLabels,
        now: Date,
        calendar: Calendar = .current,
        onToggleState: @escaping (TaskWithLabels) -> Void,
        onPress: @escaping (TaskWithLabels) -> Void
    ) {
        self.row = row
        self.now = now
        self.calendar = calendar
        self.onToggleState = onToggleState
        self.onPress = onPress
    }

    public var body: some View {
        let muted = row.task.state.isTerminal
        HStack(alignment: .top, spacing: 12) {
            TodoStateBox(state: row.task.state) { onToggleState(row) }
            VStack(alignment: .leading, spacing: 7) {
                Text(row.task.title)
                    .font(.system(size: 14))
                    .strikethrough(row.task.state == .cancelled, color: theme.inkFaint)
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !row.labels.isEmpty || row.task.dueAt != nil {
                    HStack(spacing: 5) {
                        ForEach(row.labels) { TodoTagChip(label: $0) }
                        if let due = row.task.dueAt {
                            Text("· \(dueText(due))")
                                .font(.system(size: 10, design: .monospaced))
                                .fontWeight(dueIsToday(due) && !muted ? .semibold : .regular)
                                .foregroundStyle(dueIsToday(due) && !muted ? Self.dueAccent : theme.inkFaint)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .opacity(muted ? 0.62 : 1)
        .padding(.vertical, 13)
        .padding(.trailing, 14)
        .padding(.leading, 16)
        .background(theme.backgroundRaised)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(stripeColor)
                .frame(width: 3)
                .opacity(muted ? 0.35 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(theme.borderFaint, lineWidth: 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture { onPress(row) }
    }

    /// Priority stripe color from the design's `priColor`:
    /// `oklch(0.62 0.14 hue)` against the task's priority hue.
    private var stripeColor: Color {
        OKLCH(0.62, 0.14, row.task.priority.hue).color
    }

    /// Warm red for a due-today badge — the design's `oklch(0.5 0.16 25)`.
    private static let dueAccent = OKLCH(0.5, 0.16, 25).color

    private func dueIsToday(_ date: Date) -> Bool {
        calendar.isDate(date, inSameDayAs: now)
    }

    private func dueText(_ date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Inline label chip — a small filled capsule. Used by `TodoTaskRow` and
/// the tag picker. Colors derive from the label's stored hue via the
/// design's `tagBg` / `tagFg` OKLCH formulas.
struct TodoTagChip: View {
    let label: LabelRecord

    var body: some View {
        Text(label.name)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(OKLCH(0.94, 0.035, label.hue).color)
            .foregroundStyle(OKLCH(0.4, 0.08, label.hue).color)
            .clipShape(Capsule())
    }
}
