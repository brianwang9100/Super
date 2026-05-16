import Core
import SwiftUI

/// Inline label picker used inside `TodoTaskEditorSheet`. Selected labels
/// render as removable chips beside a text field; typing filters the
/// unselected pool, and a query with no exact match surfaces a
/// "＋ Create" affordance. Mirrors `TagPicker` in the Todo design source's
/// `sheets.jsx`.
struct TodoTagPicker: View {
    /// Every active label, for resolving names/colors and filtering.
    let labels: [LabelRecord]
    /// The draft's selected label ids.
    @Binding var selectedIds: [String]
    /// Create-or-fetch a label by name; returns its canonical id.
    let onCreate: (String) async -> String?

    @State private var query = ""
    @FocusState private var fieldFocused: Bool
    @Environment(\.superFontScale) private var fontScale
    @Environment(\.superTheme) private var theme

    private var labelsByID: [String: LabelRecord] {
        Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) })
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasExactMatch: Bool {
        labels.contains { $0.name.lowercased() == trimmedQuery.lowercased() }
    }

    private var suggestions: [LabelRecord] {
        let unselected = labels.filter { !selectedIds.contains($0.id) }
        guard !trimmedQuery.isEmpty else { return unselected }
        return unselected.filter { $0.name.lowercased().contains(trimmedQuery.lowercased()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            inputRow
            if !trimmedQuery.isEmpty && !hasExactMatch {
                createButton
            }
            if !suggestions.isEmpty {
                suggestionChips
            }
        }
    }

    /// Selected-label chips wrap with the text field via `FlowLayout` so a
    /// long label set grows the box downward instead of demanding a wider
    /// row — an `HStack` here reported an intrinsic width past the screen
    /// edge and pushed the whole editor sheet wider.
    private var inputRow: some View {
        FlowLayout(spacing: 5) {
            ForEach(selectedIds, id: \.self) { id in
                if let label = labelsByID[id] {
                    selectedChip(label)
                }
            }
            TextField(selectedIds.isEmpty ? "Search or create…" : "", text: $query)
                .font(.system(size: 15 * fontScale))
                .foregroundStyle(theme.ink)
                .focused($fieldFocused)
                .submitLabel(.done)
                .onSubmit(create)
                .onKeyPress(.delete) {
                    if query.isEmpty, let last = selectedIds.last {
                        selectedIds.removeAll { $0 == last }
                        return .handled
                    }
                    return .ignored
                }
                .frame(minWidth: 110)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 36)
        .background(theme.backgroundRaised)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.borderFaint, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func selectedChip(_ label: LabelRecord) -> some View {
        HStack(spacing: 4) {
            Text(label.name)
                .font(.system(size: 14 * fontScale, weight: .medium))
            Button {
                selectedIds.removeAll { $0 == label.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10 * fontScale, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(OKLCH(0.94, 0.035, label.hue).color)
        .foregroundStyle(OKLCH(0.4, 0.08, label.hue).color)
        .clipShape(Capsule())
    }

    private var createButton: some View {
        Button(action: create) {
            HStack(spacing: 9) {
                Image(systemName: "plus")
                    .font(.system(size: 12 * fontScale, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(theme.accent)
                    .clipShape(Circle())
                Text("Create \"\(trimmedQuery)\"")
                    .font(.system(size: 15 * fontScale, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(theme.accentSoft)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var suggestionChips: some View {
        FlowLayout(spacing: 5) {
            ForEach(suggestions) { label in
                Button {
                    selectedIds.append(label.id)
                    query = ""
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(OKLCH(0.4, 0.08, label.hue).color)
                            .frame(width: 7, height: 7)
                        Text(label.name)
                            .font(.system(size: 14 * fontScale, weight: .medium))
                    }
                    .foregroundStyle(theme.inkSoft)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .overlay(Capsule().strokeBorder(theme.borderFaint, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func create() {
        let name = trimmedQuery
        guard !name.isEmpty, !hasExactMatch else { return }
        Task {
            if let id = await onCreate(name), !selectedIds.contains(id) {
                selectedIds.append(id)
            }
            query = ""
            fieldFocused = true
        }
    }
}
