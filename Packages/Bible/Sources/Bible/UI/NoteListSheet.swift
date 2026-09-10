import Core
import SwiftUI

struct NoteListSheet: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    struct Item: Sendable, Identifiable, Equatable {
        let id: String
        let dateWritten: String
        let text: String
        let author: String?

        init(id: String, dateWritten: String, text: String, author: String? = nil) {
            self.id = id
            self.dateWritten = dateWritten
            self.text = text
            self.author = author
        }
    }

    let citation: String
    let items: [Item]
    /// Reserve for the minimized chat pill; zero in standalone contexts.
    let bottomInset: CGFloat
    let onClose: () -> Void
    let onCompose: () -> Void
    let onSelect: (Item.ID) -> Void
    let onDelete: (Item.ID) -> Void

    private let sizing = SheetSizing.expandable

    init(
        citation: String,
        items: [Item],
        onClose: @escaping () -> Void,
        onCompose: @escaping () -> Void,
        onSelect: @escaping (Item.ID) -> Void,
        onDelete: @escaping (Item.ID) -> Void,
        bottomInset: CGFloat = 0
    ) {
        self.citation = citation
        self.items = items
        self.onClose = onClose
        self.onCompose = onCompose
        self.onSelect = onSelect
        self.onDelete = onDelete
        self.bottomInset = bottomInset
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetNavBar(
                title: citation,
                subtitle: "\(items.count) \(items.count == 1 ? "Note" : "Notes")",
                sizing: sizing,
                onClose: onClose
            ) {
                composeButton
            }
            Rectangle()
                .fill(theme.borderFaint)
                .frame(height: 0.5)
            if items.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                noteList
            }
        }
        .sheetPresentation(sizing)
    }

    private var composeButton: some View {
        Button(action: onCompose) {
            Image(systemName: "plus")
                .font(typography.font(size: 16, weight: .semibold))
                .foregroundStyle(theme.accentInk)
                .frame(width: 44, height: 44)
                .superGlassCTAButton(in: Circle())
        }
        .buttonStyle(GlassHapticButtonStyle(.primary))
        .accessibilityLabel("Write a note")
    }

    private var noteList: some View {
        List {
            ForEach(items) { item in
                Button {
                    onSelect(item.id)
                } label: {
                    NoteCard(dateWritten: item.dateWritten, text: item.text, author: item.author)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(for: item))
                .accessibilityHint("Opens the note for editing")
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
                // Require a deliberate delete-button tap; a full swipe only reveals the action.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        onDelete(item.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            // Combine with the last row's 5pt inset for 24pt spacing, then add pill clearance.
            Color.clear
                .frame(height: 19 + bottomInset)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .accessibilityHidden(true)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 20)
                .fill(theme.backgroundSunken)
                .frame(width: 64, height: 64)
                .overlay { NoteGlyph(state: .outline, size: 30) }
            Text("No notes yet")
                .font(typography.font(size: 16, weight: .semibold))
                .foregroundStyle(theme.ink)
            Text("Tap + to write the first note on this passage.")
                .font(typography.font(size: 14))
                .lineSpacing(2)
                .foregroundStyle(theme.inkSoft)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 230)
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 40)
    }

    private func accessibilityLabel(for item: Item) -> String {
        // Include content in the spoken label, not only its date.
        let origin = item.author.map { "Note written by \($0) on \(item.dateWritten)" }
            ?? "Note from \(item.dateWritten)"
        return "\(origin): \(item.text)"
    }
}
