# SuperBible — Notes

User-authored free-text notes on a scripture range. A sibling to **Annotations**:
annotations are AI-generated study *cards* (machine-spoken → a speech bubble); notes are
something the reader (or the assistant) *writes down* (→ a folded page glyph). The two
features are fully decoupled — separate table, repository, glyph, sheets, and Chat tool —
but share the annotations architecture: polymorphic book/chapter/verse scope, GRDBQuery
`@Query` reactive binding, stateless SwiftUI views + view-model choreography, and a
composition-root-injected Chat tool (no cross-applet import).

A future general **Notes applet** (browse all notes across books) is **out of scope** —
these notes live in the Bible package only.

## Contents
1. What this is
2. Concepts & terminology
3. Data model
4. The `bible.note` tool
5. UI affordances
6. Chat integration
7. Reactive glyph visibility
8. Accessibility
9. Package additions
10. Testing
11. Milestones & PR bundling
12. References

## 1. What this is

A reader selects a verse (or chapter/book) and writes a note. A small **folded-page glyph**
then trails the passage; tapping it opens the **Note List** sheet for that exact range, where
notes can be added, edited, and deleted individually. The assistant can do the same through a
`bible.note` Chat tool. Unlike annotations' regenerate-the-whole-set model, notes are **true
per-row CRUD**.

## 2. Concepts & terminology

- **Note** — one user- or assistant-authored free-text entry on a scripture *target*.
- **Target** — `book` | `chapter` | `verse` (a verse *range*). Same polymorphism as annotations.
- **Range key** — `(target, bookId, chapterNumber?, verseStart?, verseEnd?)`. Notes group by
  exact range; overlapping ranges ending on the same verse stack their glyphs.
- **NoteGlyph** — the inline folded-page indicator. **filled** = a note exists (the only
  in-product state at verse level); **outline** = empty/tap-to-add affordance (chapter titles,
  book-picker rows, and the list empty-state hero).
- **VerseTrailers** — the inline cluster after a verse number. Stable order: **annotation
  bubble first (left), note glyph second (right)**, 3px gap, baseline-aligned.

## 3. Data model

### `bibleNote` table

Polymorphic single table (mirrors `bibleAnnotation`), minus annotation's `kind`/`title`, plus
`updatedAt` (notes are editable). New migration in `BibleDatabase.swift`, version after
annotations' v3.

| column | type | notes |
|---|---|---|
| `id` | TEXT PK | UUID |
| `target` | TEXT | `book` \| `chapter` \| `verse` |
| `bookId` | TEXT | 3-letter code, e.g. `JHN` |
| `chapterNumber` | INT? | set for chapter/verse |
| `verseStart` | INT? | set for verse |
| `verseEnd` | INT? | set for verse (`>= verseStart`) |
| `body` | TEXT | free text, no title |
| `source` | TEXT | `user` \| `assistant` |
| `modelId` | TEXT? | nil for `user`; LLM id when `assistant` |
| `createdAt` | DATETIME | "date written" on the card |
| `updatedAt` | DATETIME | bumped on edit |

Indexes (mirror annotations):
- `bibleNote_on_bookId_chapterNumber_verseEnd` — chapter render + per-verse grouping.
- `bibleNote_on_target_bookId` — book-picker glyph visibility.

### Swift surface

`BibleNoteRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable`
(`Models/BibleNoteRecord.swift`), `static let databaseTableName = "bibleNote"`. New enums
`BibleNoteTarget` and `BibleNoteSource` alongside it — **do not** reuse the annotation enums
(keep the features decoupled).

### Repository — true per-row CRUD

`Repositories/BibleNoteRepository.swift` (protocol seam) + `GRDBBibleNoteRepository.swift`.

```swift
public protocol BibleNoteRepository: Sendable {
    func list(target: BibleNoteTarget, bookId: String,
              chapterNumber: Int?, verseStart: Int?, verseEnd: Int?) async throws -> [BibleNoteRecord]
    func insert(_ note: BibleNoteRecord) async throws
    func update(id: String, body: String, updatedAt: Date) async throws   // no-op if missing
    func deleteOne(id: String) async throws                                // no-op if missing
}
```

Reuse the nullable-column equality pattern (`applyNullableEquality`) from
`GRDBBibleAnnotationRepository`. `list(...)` orders `createdAt DESC, id ASC` (newest first).

## 4. The `bible.note` tool

`Tools/NoteBibleTool.swift`, modeled on `AnnotateBibleTool`. **One** tool with an `action`
enum — `{create, edit, delete}`.

- Descriptor: id `bible.note`, category `.mutation`, appletId `bible`.
- Parameters: `action`; `target` + position fields (`bookId`, `chapterNumber`, `verseStart`,
  `verseEnd`) for `create`; `body` for `create`/`edit`; `id` for `edit`/`delete`.
- **Soft validation** (return `ToolResult(isError: true)` with remediation text, don't throw),
  matching the annotation tool: missing `id` on edit/delete, empty `body` on create, position
  fields inconsistent with `target`.
- Executor holds an injected `BibleNoteRepository`; stamps `source = .assistant`, `modelId`,
  and timestamps via injected `Clock` / `IDGenerator` (test seams — no direct `Date.now()`).
  Returns `ToolResult` with the affected note id as an artifact.
- Registration: `BibleApplet.registerNoteTool(in:)` (parallel to `registerAnnotationTool`),
  called from `SuperOSAppBootstrap` and the SuperBible bootstrap. No cross-applet import.

## 5. UI affordances

All in `Packages/Bible/Sources/Bible/UI/`. Stateless views; the coordinator supplies data +
callbacks. SuperTheme tokens throughout; destructive actions use `errorAccent`.

### `NoteGlyph` (sibling to `AnnotationBubble`)
Hand-drawn 24×24 `Path`, 1.6 stroke, rounded caps/joins — a **portrait page with a turned-down
top-right corner and two ruled lines**. (Design paths: body
`M14 3.4H7A2 2 0 0 0 5 5.4V18.6A2 2 0 0 0 7 20.6H17A2 2 0 0 0 19 18.6V8.4Z`, fold
`M14 3.4V6.8A1.6 1.6 0 0 0 15.6 8.4H19`, rules `M8.6 13H15.4` / `M8.6 16.2H15.4`.)
- **filled** — solid `accent` page; crease + rules knocked in with `accentInk` at 0.85 opacity.
- **outline** — `inkFaint` stroke, used as the tap-to-add affordance and empty-state hero.

Named `NoteGlyph` rather than `*Bubble` (the naming-doc small-mark bucket) because it is not
bubble-shaped and must read as visually *distinct* from `AnnotationBubble` — confirm against
`NAMING_CONVENTIONS.md` Part 4 at implementation; if the bucket is mandatory, fall back to
`NoteMark`.

### `VerseTrailers`
The inline cluster after a verse number — annotation bubble then note glyph, 3px gap. In the
reader this **replaces the bare annotation bubble** that the annotations reader integration
adds, so the two glyph systems sit in a stable order. (See §7 and the PR3 sequencing note.)

### `NoteCard`
List row: `backgroundRaised`, 0.5px `borderFaint`, 16-radius. Mono uppercase **date written**,
then **body clamped to 4 lines** (system font, tail ellipsis). Assistant-written notes get a
subtle provenance footer — `Sparkle` icon + "Written by {author}" in `inkMute`; user notes
have none. Swipe-to-delete reveals an `errorAccent` Delete action. XXL Dynamic Type variant.

### `NoteListSheet`
Bottom sheet (drag handle) hosting its **own navigation bar**: serif **verse-range citation**
title + mono "{n} Note(s)" subtitle + a round `accent` **+** button. Body scrolls `NoteCard`s.
Detents large/medium. **Empty state**: sunken rounded tile with an outline `NoteGlyph`,
"No notes yet", and "Tap + to write the first note on this passage."

### `NoteEditor`
Create/edit modal over the dimmed reader + scrim. Drag handle; toolbar as three circular icon
buttons — **✕ Cancel** (sunken), title ("New note" / "Edit note"), **✓ Save** (accent;
disabled + dimmed while body is empty). Mono "ON {citation}" caption, large free-text area
with an accent caret. **Edit mode** adds an error-tinted **Delete note** button →
`DeleteConfirm`.

### `DeleteConfirm`
iOS-style destructive confirmation (`.confirmationDialog`): grouped prompt "Delete this note?"
/ "This can't be undone.", a destructive **Delete note**, and a separate **Cancel**.

### Action sheet & book picker
- `BibleActionSheet` gains an **"Add note"** accent tile beside "Annotate" (same `accentSoft`
  tile treatment; icon = filled `NoteGlyph`). Tapping → `NoteEditor` create for the range.
- Book picker rows (and chapter titles) carry **both** glyphs in stable order, each **outline
  until something of that kind exists, then filled**. Tapping an outline glyph starts a
  note on that whole book/chapter (opens `NoteEditor` create with the matching target).

## 6. Chat integration

- **Chat → notes (write):** the `bible.note` tool (§4). The executor holds the injected
  repository; the assistant's note persists with `source = .assistant` and is attributed in the
  card footer.
- **Bible → Chat (hand-off):** unchanged — the action sheet's existing "Add to chat" / "New
  chat" rows publish a generic `RecordReference` on `SuperEventBus`. Notes add nothing here.

## 7. Reactive glyph visibility

Per the Bible reactive rule, anything written from outside the on-screen view binds via
`@Query`. New `ValueObservationQueryable`s in `Queries/`:
- `ChapterNotesRequest(bookId, chapterNumber)` → `[BibleNoteRecord]` — drives the reader's
  trailing note glyphs. Repaints when the tool or the editor writes.
- `NotesForRangeRequest(target, bookId, chapterNumber, verseStart, verseEnd)` → `[BibleNoteRecord]`
  — backs the list sheet so a Chat-written note appears live while it's open.
- `BookNotesExistenceRequest` → `Set<String>` of bookIds — book-picker glyph fill state.

## 8. Accessibility

Every interactive element carries an `accessibilityLabel` ("Add note", "Note on John 3:16–18",
"Delete note"). `NoteGlyph` itself is `accessibilityHidden` (the verse/row owns the label, as
`AnnotationBubble` does). Sheet presentation honors Reduce Motion via `BibleSheetMotion`. The
4-line clamp and provenance footer hold shape at Dynamic Type XXL.

## 9. Package additions

**New (`Packages/Bible/Sources/Bible/`):**
- `Models/BibleNoteRecord.swift`, `Models/BibleNoteTarget.swift`, `Models/BibleNoteSource.swift`
- `Repositories/BibleNoteRepository.swift`, `Repositories/GRDBBibleNoteRepository.swift`
- `Queries/ChapterNotesRequest.swift`, `Queries/NotesForRangeRequest.swift`, `Queries/BookNotesExistenceRequest.swift`
- `Tools/NoteBibleTool.swift`
- `UI/NoteGlyph.swift`, `UI/VerseTrailers.swift`, `UI/NoteCard.swift`, `UI/NoteListSheet.swift`, `UI/NoteEditor.swift`
- `ViewModels/NoteSheetViewModel.swift` (presentation coordinator)
- `docs/SuperBible/NOTES_FEATURE.md` (this doc)

**Modified:**
- `Database/BibleDatabase.swift` — `bibleNote` migration + indexes
- `Applet/BibleApplet.swift` — open note repository, `registerNoteTool(in:)`
- `UI/BibleActionSheet.swift` — "Add note" tile
- `UI/BibleChapterReader.swift` + book-picker view — host the note `@Query`s, render `VerseTrailers`
- `BibleScreenViewModel` — selected-range + editor/list presentation
- `SuperOSAppBootstrap.swift` + SuperBible bootstrap — call `registerNoteTool`
- `App-SuperBible/PRIVACY.md` — notes are user text stored on-device only

**Reused as-is:** `BibleCitationFormatter.cite(...)` (range titles), `AnnotationBubble` +
its stacking contract (co-trailing), Core `ToolExecutor`/`LLMTool`/`ToolRegistration`,
`applyNullableEquality`, the shared `AI` icon set (`Sparkle`, `Plus`, `Trash`, `Check`, `Close`).

## 10. Testing

- **Unit / integration:** `BibleNoteRepository` against an in-memory `DatabaseQueue` (CRUD +
  range queries + nullable matching) with `GRDBSnapshotTesting` for schema shape; the three
  `@Query` requests' fetch logic; a cross-write test proving a tool-written note repaints a
  `@Query`-bound view.
- **Tool:** `NoteBibleTool` with a mock `BibleNoteRepository` — each action + every soft-
  validation error path; registry registration through an in-memory `ToolRegistry`.
- **UI snapshots** (ship with the views, per Bible AGENTS §Tests): `NoteGlyph` (filled +
  outline), `VerseTrailers` co-trailing layout, `NoteCard` (user / assistant-provenance /
  swipe), `NoteListSheet` (empty / one / many-scrolling), `NoteEditor` (create-empty /
  edit-prefilled / delete-confirm) — across **light / dark / sepia × default Dynamic Type**,
  plus **XXL** for `NoteCard` + `NoteListSheet`, plus reader/action-sheet/book-picker
  integration snapshots in PR3. Record on the CI trio (Xcode 26.4.1 + iOS 26.4 sim + iPhone 17)
  via the `SNAPSHOT_RECORD` env approach. Coverage stays ≥70%.

## 11. Milestones & PR bundling

Nine milestones, bundled into three PRs mirroring the annotations rollout.

| ID | Milestone |
|---|---|
| N0 | Data foundation — `BibleNoteRecord` + enums, `bibleNote` migration + indexes |
| N1 | Repository — protocol + GRDB impl (CRUD + range query) |
| N2 | Reactive queries — `ChapterNotesRequest`, `NotesForRangeRequest`, `BookNotesExistenceRequest` |
| N3 | Chat tool — `bible.note` (create/edit/delete) + composition-root registration |
| N4 | UI atoms — `NoteGlyph` (filled + outline), `VerseTrailers` cluster |
| N5 | UI sheets — `NoteCard`, `NoteListSheet` (+ empty), `NoteEditor`, `DeleteConfirm` |
| N6 | Reader integration — `VerseTrailers` via `@Query`; tap → list sheet; chapter-title outline → add chapter note |
| N7 | Action sheet + book picker — "Add note" tile; dual glyphs; tap outline → editor (book/chapter scope) |
| N8 | Presentation coordinator + bootstrap wiring + `PRIVACY.md` |

**PR 1 — Data, queries, tool, doc** (N0–N3 + `NOTES_FEATURE.md`). No UI.
Tests: repository integration + schema snapshot, `@Query` fetch tests, `NoteBibleTool` tests
(all actions + soft-validation), registry registration test.

**PR 2 — UI in isolation** (N4–N5). Stateless views + the full snapshot matrix above.

**PR 3 — Integration + privacy** (N6–N8). Reader/action-sheet/book-picker wiring, presentation
coordinator, `PRIVACY.md`. Tests: reactive cross-write repaint, reader snapshot with co-trailing
glyphs, action-sheet + book-picker snapshots.
**Sequencing dependency:** PR 3 should land **after the annotations reader integration (their
PR3)**, because it refactors the reader's bare annotation bubble into the shared `VerseTrailers`
cluster. PR 1 and PR 2 have no such dependency and can proceed immediately.

## 12. References

- `docs/SuperBible/ANNOTATIONS.md` — the sibling feature this mirrors.
- `Packages/Bible/Sources/Bible/Models/BibleAnnotationRecord.swift`, `…/Repositories/GRDBBibleAnnotationRepository.swift`,
  `…/Tools/AnnotateBibleTool.swift`, `…/UI/AnnotationBubble.swift`, `…/Queries/ChapterAnnotationsRequest.swift`.
- `Packages/Core/Sources/Core/Theme/SuperTheme.swift` — tokens incl. `errorAccent`.
- Claude Design canvas `super/project/notes/*.jsx` (design source of record).
