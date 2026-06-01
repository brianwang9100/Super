import Core
import GRDBQuery
import SwiftUI

/// Region wrapping the stateless `NoteListSheet` with the live GRDB query
/// that feeds it and the editor it presents on top.
///
/// Like `AnnotationSheetContainer`, the container owns no `@Observable` view
/// model: the projection of DB rows into the list is a `@Query` binding at the
/// view layer, so a note written from anywhere — the editor here, an in-chat
/// `bible.note` tool call — repaints the list automatically (Bible AGENTS
/// "reactive vs imperative reads"). The only state it owns is the *editor
/// presentation* (`editing`), which is transient UI flow state belonging to
/// this sheet alone — not a projection of the database — so it's a local
/// `@State`, not a view model.
///
/// Writes route back out through `onCreate` / `onUpdate` / `onDelete`, which
/// `BibleScreen` closes onto `BibleScreenViewModel` (which holds the note
/// repository, clock, and id generator and surfaces a toast on failure). The
/// container never touches the repository directly — it reads reactively and
/// delegates writes, keeping id/timestamp stamping in one place.
struct NoteListSheetContainer: View {
    /// The range whose notes this sheet lists.
    let spec: BibleNoteTargetSpec
    /// Header citation, e.g. `"John 3:16-18"`. Built by the parent because the
    /// citation formatter needs the book's display name (which the view model
    /// already holds).
    let citation: String
    /// Open the editor in create mode the instant the sheet mounts — the
    /// "Add note" / outline-glyph entry points set this so the user lands
    /// straight in composition rather than on the list.
    let autoCompose: Bool
    let bottomInset: CGFloat
    /// Persist a new note with this body on `spec`.
    let onCreate: (String) -> Void
    /// Replace note `id`'s body.
    let onUpdate: (_ id: String, _ body: String) -> Void
    /// Delete note `id`.
    let onDelete: (_ id: String) -> Void

    @Query<NotesForRangeRequest> private var records: [BibleNoteRecord]

    /// The editor currently presented over the list, or `nil` when the list
    /// is showing. Transient flow state owned by this sheet.
    @State private var editing: Editing?
    /// One-shot latch so `autoCompose` opens the editor exactly once per
    /// appearance — `onAppear` can fire repeatedly (e.g. the editor sheet
    /// dismissing), and without this a cancelled auto-compose would reopen.
    @State private var didAutoCompose = false

    init(
        spec: BibleNoteTargetSpec,
        citation: String,
        autoCompose: Bool = false,
        bottomInset: CGFloat = 0,
        onCreate: @escaping (String) -> Void,
        onUpdate: @escaping (_ id: String, _ body: String) -> Void,
        onDelete: @escaping (_ id: String) -> Void
    ) {
        self.spec = spec
        self.citation = citation
        self.autoCompose = autoCompose
        self.bottomInset = bottomInset
        self.onCreate = onCreate
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        self._records = Query(constant: NotesForRangeRequest(
            target: spec.target,
            bookId: spec.bookId,
            chapterNumber: spec.chapterNumber,
            verseStart: spec.verseStart,
            verseEnd: spec.verseEnd
        ))
    }

    var body: some View {
        NoteListSheet(
            citation: citation,
            items: items,
            onCompose: { editing = .create },
            onSelect: { id in
                guard let item = items.first(where: { $0.id == id }) else { return }
                editing = .edit(item)
            },
            onDelete: onDelete,
            bottomInset: bottomInset
        )
        .onAppear {
            guard autoCompose, !didAutoCompose else { return }
            didAutoCompose = true
            editing = .create
        }
        .sheet(item: $editing) { editing in
            editor(for: editing)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
    }

    @ViewBuilder
    private func editor(for editing: Editing) -> some View {
        switch editing {
        case .create:
            NoteEditor(
                citation: citation,
                mode: .create,
                onSave: { body in
                    onCreate(body)
                    self.editing = nil
                },
                onCancel: { self.editing = nil },
                onDelete: { self.editing = nil }
            )
        case .edit(let item):
            NoteEditor(
                citation: citation,
                mode: .edit,
                initialText: item.text,
                onSave: { body in
                    onUpdate(item.id, body)
                    self.editing = nil
                },
                onCancel: { self.editing = nil },
                onDelete: {
                    onDelete(item.id)
                    self.editing = nil
                }
            )
        }
    }

    /// The observed rows projected into list items: the body verbatim, the
    /// `createdAt` formatted as the card's "date written", and the assistant
    /// author (for the provenance footer) derived from `source`/`modelId` —
    /// `nil` for user notes, which carry no footer.
    private var items: [NoteListSheet.Item] {
        records.map { record in
            NoteListSheet.Item(
                id: record.id,
                dateWritten: Self.dateFormatter.string(from: record.createdAt),
                text: record.body,
                author: Self.author(for: record)
            )
        }
    }

    /// The provenance author for an assistant note, or `nil` for a user note.
    /// Empty / nil `modelId` on an assistant row falls back to `"AI"` so the
    /// footer still reads sensibly — mirroring `AnnotationSheetContainer`.
    private static func author(for record: BibleNoteRecord) -> String? {
        guard record.source == .assistant else { return nil }
        guard let modelId = record.modelId, !modelId.isEmpty else { return "AI" }
        return modelId
    }

    /// Shared formatter for the "date written" line. Created once because
    /// `DateFormatter` allocation is expensive and the list may render many
    /// rows — the same rationale `AnnotationSheetContainer` uses.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        // Follow the reader's locale so the "date written" line localizes with
        // the rest of the app rather than freezing at the locale that first
        // touched the static formatter.
        formatter.locale = Locale.autoupdatingCurrent
        return formatter
    }()

    /// Which editor is presented over the list. `Identifiable` so the nested
    /// `.sheet(item:)` re-presents when switching between create and editing
    /// a specific note.
    private enum Editing: Identifiable, Equatable {
        case create
        case edit(NoteListSheet.Item)

        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let item): return "edit:\(item.id)"
            }
        }
    }
}
