import Core
import SwiftUI

/// The bottom sheet that lists every note on one scripture range.
///
/// Anatomy (top to bottom), per `notes/sheet.jsx`:
///
/// - **Drag handle** — the standard 36×4 capsule the other Bible sheets use.
/// - **Its own navigation bar** — a serif verse-range citation title, a
///   mono "{n} Note(s)" subtitle, and a round `accent` **+** button that
///   composes a new note on this range.
/// - **Body** — a scroll of `NoteCard` rows (tap a card to edit, swipe to
///   delete), or the empty-state hero when the range has no notes yet.
///
/// Stateless: it owns no GRDB `@Query`, view model, or event-bus publish.
/// The PR3 container supplies the projected `items` from the live
/// `NotesForRangeRequest` and closes the three callbacks onto the editor,
/// the repository, and (for compose) the editor's create path.
struct NoteListSheet: View {
    @Environment(\.superTheme) private var theme

    /// One projected note row. The container maps each `BibleNoteRecord`
    /// into an `Item`, formatting the date and deriving the assistant
    /// `author` from `source`/`modelId` before constructing it.
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

    /// Display citation in the nav bar, e.g. `"John 3:16–18"`.
    let citation: String
    let items: [Item]
    /// Extra bottom padding so the last card clears the shell's minimized
    /// chat pill; `0` in standalone (snapshot) contexts.
    let bottomInset: CGFloat
    let onCompose: () -> Void
    let onSelect: (Item.ID) -> Void
    let onDelete: (Item.ID) -> Void

    // Nav-bar font sizes scaled to Dynamic Type (the `BibleBookSheet`
    // convention); the round + button stays a fixed control glyph.
    @ScaledMetric(relativeTo: .title2) private var citationSize: CGFloat = 21
    @ScaledMetric(relativeTo: .caption2) private var countSize: CGFloat = 10

    init(
        citation: String,
        items: [Item],
        onCompose: @escaping () -> Void,
        onSelect: @escaping (Item.ID) -> Void,
        onDelete: @escaping (Item.ID) -> Void,
        bottomInset: CGFloat = 0
    ) {
        self.citation = citation
        self.items = items
        self.onCompose = onCompose
        self.onSelect = onSelect
        self.onDelete = onDelete
        self.bottomInset = bottomInset
    }

    var body: some View {
        VStack(spacing: 0) {
            grabber
            navBar
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
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26)
                .fill(theme.background)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var grabber: some View {
        Capsule()
            .fill(theme.inkMute)
            .frame(width: 36, height: 4)
            .opacity(0.45)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .accessibilityHidden(true)
    }

    private var navBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(citation)
                    .font(.system(size: citationSize, weight: .semibold, design: .serif))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(items.count) \(items.count == 1 ? "Note" : "Notes")")
                    .font(.system(size: countSize, weight: .medium, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(theme.inkFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onCompose) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.accentInk)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(theme.accent))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Write a note")
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 12)
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
                // `allowsFullSwipe: false` so a full swipe reveals the Delete
                // action rather than firing it — deletion always takes a
                // deliberate tap on the revealed button (no one-gesture,
                // no-undo data loss), symmetric with the editor's path.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        onDelete(item.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            // Bottom spacer so the last card clears the shell's chat pill.
            // 19 + the last row's 5pt bottom inset = the design's 24pt
            // scroll-container bottom pad; `bottomInset` adds the pill clearance.
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.ink)
            Text("Tap + to write the first note on this passage.")
                .font(.system(size: 14))
                .lineSpacing(2)
                .foregroundStyle(theme.inkSoft)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 230)
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 40)
    }

    private func accessibilityLabel(for item: Item) -> String {
        if let author = item.author {
            return "Note written by \(author) on \(item.dateWritten)"
        }
        return "Note from \(item.dateWritten)"
    }
}
