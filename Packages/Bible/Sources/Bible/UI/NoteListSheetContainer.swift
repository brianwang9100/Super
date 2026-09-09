import Core
import GRDBQuery
import SwiftUI

/// Owns transient editor presentation and reactive reads. Delegate writes to the
/// view model so ID/timestamp stamping and failure reporting have one owner.
struct NoteListSheetContainer: View {
    let spec: BibleNoteTargetSpec
    let citation: String
    /// Opens create mode on mount for Add note; glyph taps leave this false.
    let autoCompose: Bool
    let bottomInset: CGFloat
    let onClose: () -> Void
    let onCreate: (String) -> Void
    let onUpdate: (_ id: String, _ body: String) -> Void
    let onDelete: (_ id: String) -> Void

    @Query<NotesForRangeRequest> private var records: [BibleNoteRecord]

    @State private var editing: Editing?
    // onAppear may repeat after editor dismissal; do not reopen cancelled auto-compose.
    @State private var didAutoCompose = false

    init(
        spec: BibleNoteTargetSpec,
        citation: String,
        autoCompose: Bool = false,
        bottomInset: CGFloat = 0,
        onClose: @escaping () -> Void,
        onCreate: @escaping (String) -> Void,
        onUpdate: @escaping (_ id: String, _ body: String) -> Void,
        onDelete: @escaping (_ id: String) -> Void
    ) {
        self.spec = spec
        self.citation = citation
        self.autoCompose = autoCompose
        self.bottomInset = bottomInset
        self.onClose = onClose
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
            onClose: onClose,
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

    private static func author(for record: BibleNoteRecord) -> String? {
        guard record.source == .assistant else { return nil }
        guard let modelId = record.modelId, !modelId.isEmpty else { return "AI" }
        return modelId
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        // Keep dates aligned with live locale changes.
        formatter.locale = Locale.autoupdatingCurrent
        return formatter
    }()

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
