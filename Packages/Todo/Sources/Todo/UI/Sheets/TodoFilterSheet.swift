import Core
import SwiftUI

/// Bottom sheet for sorting and filtering the task list — sort order, state
/// scope, and label multi-select. Mirrors `FilterSheet` in the Todo design
/// source's `sheets.jsx`. The `Manual` sort case is intentionally not
/// offered (deferred until a reorder UX exists).
struct TodoFilterSheet: View {
    @Binding var filter: TodoFilter
    let labels: [LabelRecord]
    let onClose: () -> Void

    @Environment(\.superFontScale) private var fontScale
    @Environment(\.superTheme) private var theme

    /// Sort cases the sheet exposes — `.manual` is omitted per MVP scope.
    private let sortOptions: [(TodoFilter.Sort, String)] = [
        (.priority, "Priority"),
        (.dueDate, "Due date"),
        (.newest, "Newest"),
    ]

    private let stateOptions: [TodoFilter.StateScope] = [.open, .done, .cancelled, .all]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            section("Sort by") {
                FlowLayout(spacing: 6) {
                    ForEach(sortOptions, id: \.0) { option, title in
                        pill(title, selected: filter.sort == option) { filter.sort = option }
                    }
                }
            }
            section("Show") {
                FlowLayout(spacing: 6) {
                    ForEach(stateOptions, id: \.self) { scope in
                        pill(scope.displayName, selected: filter.state == scope) { filter.state = scope }
                    }
                }
            }
            section("Tags · any selected") {
                if labels.isEmpty {
                    Text("No labels yet.")
                        .font(.system(size: 14 * fontScale))
                        .foregroundStyle(theme.inkFaint)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(labels) { label in
                            tagChip(label)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 24)
        .background(theme.background)
    }

    private var header: some View {
        HStack {
            Text("Sort & filter")
                .font(.system(size: 17 * fontScale, weight: .semibold))
                .foregroundStyle(theme.ink)
            Spacer()
            Button("Reset") {
                filter = .defaults
            }
            .font(.system(size: 15 * fontScale))
            .foregroundStyle(theme.inkFaint)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 13 * fontScale, weight: .medium, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(theme.inkFaint)
            content()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private func pill(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15 * fontScale, weight: .medium))
                .foregroundStyle(selected ? theme.accentInk : theme.inkSoft)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected ? theme.accent : theme.backgroundRaised)
                .overlay(
                    Capsule().strokeBorder(selected ? .clear : theme.borderFaint, lineWidth: 1)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func tagChip(_ label: LabelRecord) -> some View {
        let selected = filter.labelIds.contains(label.id)
        return Button {
            if selected {
                filter.labelIds.remove(label.id)
            } else {
                filter.labelIds.insert(label.id)
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(OKLCH(0.4, 0.08, label.hue).color)
                    .frame(width: 6, height: 6)
                Text(label.name)
                    .font(.system(size: 14 * fontScale, weight: .medium))
            }
            .foregroundStyle(selected ? OKLCH(0.4, 0.08, label.hue).color : theme.inkSoft)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(selected ? OKLCH(0.94, 0.035, label.hue).color : theme.backgroundRaised)
            .overlay(
                Capsule().strokeBorder(
                    selected ? OKLCH(0.4, 0.08, label.hue).color : theme.borderFaint,
                    lineWidth: 1
                )
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
