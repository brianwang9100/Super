import Core
import SwiftUI

/// Bottom sheet for sorting and filtering the task list — sort order, state
/// scope, and label multi-select. Mirrors `FilterSheet` in the Todo design
/// source's `sheets.jsx`. The `Manual` sort case is intentionally not
/// offered (deferred until a reorder UX exists).
struct TodoFilterSheet: View {
    @Binding var filter: TodoFilter
    let labels: [LabelRecord]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

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
                        .font(typography.font(size: 14))
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
        .sheetPresentation(.expandable)
    }

    /// Shared sheet nav bar: leading close, centered title, and a trailing
    /// glass **Reset** that restores the default filter. The 44pt trailing slot
    /// is icon-sized (the bar's convention), so Reset reads as the
    /// counter-clockwise glyph rather than the old inline text label.
    private var header: some View {
        SheetNavBar(
            title: "Sort & filter",
            sizing: .expandable,
            onClose: { dismiss() }
        ) {
            Button {
                filter = .defaults
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(typography.font(size: 16, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .frame(width: 44, height: 44)
                    .superGlassButton(in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reset filters")
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(typography.font(size: 13, weight: .medium, design: .monospaced))
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
                .font(typography.font(size: 15, weight: .medium))
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
                    .font(typography.font(size: 14, weight: .medium))
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
