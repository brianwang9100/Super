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

    @State private var query: String
    @FocusState private var fieldFocused: Bool
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    /// - Parameter initialQuery: Snapshot-only test seam — seeds the search
    ///   field so a recorded baseline can render the "＋ Create" affordance and
    ///   the filtered-suggestion state without simulating typing. Production
    ///   callers leave it empty.
    init(
        labels: [LabelRecord],
        selectedIds: Binding<[String]>,
        onCreate: @escaping (String) async -> String?,
        initialQuery: String = ""
    ) {
        self.labels = labels
        self._selectedIds = selectedIds
        self.onCreate = onCreate
        self._query = State(initialValue: initialQuery)
    }

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
                .font(typography.font(size: 15))
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
        // Passive glass field — it hosts the text input and the removable
        // selected-label chips, so the non-hit-asserting surface keeps those
        // inner taps live. Replaces the old raised fill + faint stroke.
        .superGlassSurface(in: RoundedRectangle(cornerRadius: 10))
    }

    private func selectedChip(_ label: LabelRecord) -> some View {
        HStack(spacing: 4) {
            Text(label.name)
                .font(typography.font(size: 14, weight: .medium))
            Button {
                selectedIds.removeAll { $0 == label.id }
            } label: {
                Image(systemName: "xmark")
                    .font(typography.font(size: 10, weight: .bold))
            }
            .buttonStyle(GlassHapticButtonStyle(.deselection))
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
                    .font(typography.font(size: 12, weight: .bold))
                    .foregroundStyle(theme.accentInk)
                    .frame(width: 18, height: 18)
                    // Accent call-to-action glass, matching the project's other
                    // create-`+` buttons (new chat, add task, add model).
                    .superGlassCTAButton(in: Circle())
                Text("Create \"\(trimmedQuery)\"")
                    .font(typography.font(size: 15, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(theme.accentSoft)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(GlassHapticButtonStyle(.primary))
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
                            .font(typography.font(size: 14, weight: .medium))
                    }
                    .foregroundStyle(theme.inkSoft)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    // Tappable suggestion chip → frosted glass with its own
                    // edge, in place of the old hairline-stroked capsule. Inert
                    // glass + `SuperPressButtonStyle` (not interactive glass) so
                    // a wrapping row of chips doesn't glow-flicker on release.
                    .superGlassButton(in: Capsule(), interactive: false)
                }
                .buttonStyle(GlassHapticButtonStyle(.selection, scale: true))
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
