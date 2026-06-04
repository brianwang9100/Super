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
    @Environment(\.superTypography) private var typography

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
    /// Dismisses the sheet from the nav bar's leading close button.
    let onClose: () -> Void
    let onCompose: () -> Void
    let onSelect: (Item.ID) -> Void
    let onDelete: (Item.ID) -> Void

    /// `.medium`/`.large` list sheet — same detents the book picker uses.
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

    /// Round **+** that composes a new note, hosted in the nav bar's trailing
    /// slot. Accent-tinted call-to-action glass (vs. the leading close button's
    /// neutral glass) so the primary "write a note" action reads as primary.
    private var composeButton: some View {
        Button(action: onCompose) {
            Image(systemName: "plus")
                .font(typography.font(size: 16, weight: .semibold))
                .foregroundStyle(theme.accentInk)
                .frame(width: 44, height: 44)
                .superGlassCTAButton(in: Circle())
        }
        .buttonStyle(.plain)
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
                // `allowsFullSwipe: false` so a full swipe reveals the Delete
                // action instead of firing on the swipe itself — deletion
                // takes a deliberate tap on the revealed button, not a single
                // gesture. This is the lighter, list-conventional path; the
                // editor's in-place delete adds a `.confirmationDialog` on top
                // (the two paths are intentionally not identical).
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
        // Include the note body so VoiceOver users hear the content, not
        // just "Note from <date>" — the row's whole purpose is the text.
        let origin = item.author.map { "Note written by \($0) on \(item.dateWritten)" }
            ?? "Note from \(item.dateWritten)"
        return "\(origin): \(item.text)"
    }
}
