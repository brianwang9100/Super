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

    @ScaledMetric(relativeTo: .body) private var titleSize: CGFloat = 17
    @ScaledMetric(relativeTo: .footnote) private var dueSize: CGFloat = 13
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

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
        HStack(alignment: .top, spacing: 12) {
            TodoStateBox(state: row.task.state) { onToggleState(row) }
            VStack(alignment: .leading, spacing: 7) {
                Text(row.task.title)
                    .font(typography.font(size: titleSize))
                    .strikethrough(row.task.state == .cancelled, color: theme.inkFaint)
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !row.labels.isEmpty || row.task.dueAt != nil {
                    // Chips keep their natural width and the row truncates
                    // with a trailing "…" rather than compressing chips into
                    // unreadable text-wrapped blobs. The due badge is pinned.
                    TruncatingRowLayout(spacing: 5) {
                        ForEach(row.labels) { TodoTagChip(label: $0) }
                        Text("…")
                            .font(typography.font(size: dueSize))
                            .foregroundStyle(theme.inkFaint)
                        dueBadge
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Opens the task editor")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { onPress(row) }
            Spacer(minLength: 0)
        }
        .opacity(isMuted ? 0.62 : 1)
        .padding(.vertical, 13)
        .padding(.trailing, 14)
        .padding(.leading, 16)
        .background(theme.backgroundRaised)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(stripeColor)
                .frame(width: 3)
                .opacity(isMuted ? 0.35 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(theme.borderFaint, lineWidth: 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture { onPress(row) }
    }

    /// A terminal task (done or cancelled) renders dimmed, and its due
    /// badge drops the due-today emphasis.
    private var isMuted: Bool { row.task.state.isTerminal }

    /// The pinned trailing badge for the meta line — the due date, or a
    /// zero-size placeholder when the task has none. Always emitted so
    /// `TruncatingRowLayout` can treat the last subview as the pinned slot.
    @ViewBuilder private var dueBadge: some View {
        if let due = row.task.dueAt {
            Text("· \(dueText(due))")
                .font(typography.font(size: dueSize, design: .monospaced))
                .fontWeight(dueIsToday(due) && !isMuted ? .semibold : .regular)
                .foregroundStyle(dueIsToday(due) && !isMuted ? Self.dueAccent : theme.inkFaint)
        } else {
            // A zero-size placeholder so `TruncatingRowLayout` can always
            // treat the last subview as the pinned-badge slot; measuring
            // exactly zero, it tells the layout to reserve no trailing room.
            Color.clear.frame(width: 0, height: 0)
        }
    }

    /// Spoken VoiceOver description — title plus state, priority, due, and
    /// labels — so the row reads as one meaningful element and its default
    /// "open editor" action is announced against a real label rather than
    /// the raw stacked subviews. `.onTapGesture` is invisible to VoiceOver,
    /// hence the explicit `.accessibilityAction(.default)` on the text.
    private var accessibilityLabel: String {
        var parts = [row.task.title]
        if row.task.state != .open { parts.append(row.task.state.displayName) }
        parts.append("\(row.task.priority.displayName) priority")
        if let due = row.task.dueAt { parts.append("due \(dueText(due))") }
        if !row.labels.isEmpty {
            parts.append("labels: \(row.labels.map(\.name).joined(separator: ", "))")
        }
        return parts.joined(separator: ", ")
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

/// Inline label chip — a small filled capsule shown in a task row's meta
/// line. Used only by `TodoTaskRow` (the tag *picker* renders its own inline
/// chips), so it's file-private. Colors derive from the label's stored hue
/// via the design's `tagBg` / `tagFg` OKLCH formulas.
private struct TodoTagChip: View {
    let label: LabelRecord

    @ScaledMetric(relativeTo: .footnote) private var fontSize: CGFloat = 13
    @Environment(\.superTypography) private var typography

    var body: some View {
        Text(label.name)
            .font(typography.font(size: fontSize, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(OKLCH(0.94, 0.035, label.hue).color)
            .foregroundStyle(OKLCH(0.4, 0.08, label.hue).color)
            .clipShape(Capsule())
    }
}
