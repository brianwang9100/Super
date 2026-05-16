# Bible — Agent Guidelines

The Bible mini-applet: a chapter-reading surface with verse selection, highlights, book/chapter and translation pickers.

## What lives here (incremental — builds out per the plan)

- **Applet** (`Applet/`): `BibleApplet` — `MiniApplet` conformance, applet id `"bible"`.
- **Models** (`Models/`): plain data — `BibleBook`/`BibleChapter`/`BibleParagraph`/`BibleVerse` (decoded text), `BiblePosition`/`BibleChapterDirection`/`BibleBookSummary`/`BibleBookCatalog`/`BibleBookOrder`/`BibleTranslation` (navigation), `BibleHighlightColor` (the five-colour palette), and the `BibleReadingPositionRecord` / `BibleHighlightRecord` GRDB records.
- **Database** (`Database/`): `BibleDatabase` — wraps the `bible.sqlite` `DatabaseQueue` and the schema migrator.
- **Repositories** (`Repositories/`): protocol seam + `GRDB`-prefixed impl, one pair per record.
- **Queries** (`Queries/`): GRDBQuery `ValueObservationQueryable` requests — `ChapterHighlightsRequest` is what the chapter renderer's `@Query` observes.
- **TextSources** (`TextSources/`): `BibleTextLoader` protocol + `BundledBibleTextLoader` over the bundled per-book JSON — WEB, KJV, and ASV, one `<CODE>-<bookID>.json` each. The `Scripts/generate_translation_json.py` converter regenerates them from eBible.org USFM.
- **Formatting** (`Formatting/`): `BibleCitationFormatter` — pure citation rendering, compressing contiguous verse runs to ranges (`"4-6, 9"`).
- **Clipboard** (`Clipboard/`): `ClipboardWriter` protocol + `SystemClipboard` — the injectable seam the reader's Copy action writes through.
- **ViewModels** (`ViewModels/`): `@Observable @MainActor` view models, one per screen or sheet.
- **UI** (`UI/`): SwiftUI views. **Before naming a new view, read [`docs/NAMING_CONVENTIONS.md` Part 4](../../docs/NAMING_CONVENTIONS.md#part-4--swiftui-view-layer-chat-applet).** Drop the `View` suffix, one struct per file, bucket suffix per the doc (`*Screen`, `*Sheet`, `*Bar`, `*Block`, `*Toast`, `*Bubble`, `*Footer`); composed strips inside the screen are Regions with a bare role name. `VerseFlowLayout` is the custom `Layout` that reflows tappable verse words. `BibleChapterReader` (a Region) owns the highlight `@Query`; `BibleScreen` injects the `DatabaseContext` and gives the reader a fresh identity per chapter so the constant request always matches the on-screen position.

## Rules

- **Do not import other applets.** Cross-applet communication runs through Core. Hand-off to Chat is explicitly deferred (no `SuperEventBus` work in this package).
- **No chat hand-off / bidirectional AI in MVP.** The `+` nav button and the action sheet's chat rows render per design but no-op with a "Coming soon" toast. Hand-off lands in a follow-up plan once `SuperEventBus` exists. (The floating "Ask about this chapter…" bubble was dropped — it duplicated the shell's chat composer.)
- **Persistence is GRDB only** when it lands (M2+). No SwiftData / Core Data.
- **GRDB naming**: `camelCase` Swift property names = `camelCase` columns. Foreign keys are `<referencedTableSingular>Id`. Primary key is `id` (String UUID). Indexes follow `<tableName>_on_<column>[_<column>]`. See [`docs/NAMING_CONVENTIONS.md` Part 5](../../docs/NAMING_CONVENTIONS.md#part-5--persistence-schema).
- **Records** are `struct` + `Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable`.
- **View models** are `@Observable @MainActor final class`, named `*ScreenViewModel` / `*SheetViewModel`.
- **Repositories** are protocol-typed at the seam, `GRDB`-prefixed concrete impls.
- **Inject side effects.** Clocks, ID generators, and any future network paths come through Core's protocols. No `Date()` / `UUID()` in testable logic.
- **Reactive vs. imperative reads — split by data source.** Chapter *text* is a bundled static resource and reading position is single-writer (only the Bible screen writes it): both stay imperative `@Observable` view model loads — do not reactive-ify them. *Decorations* — highlights, saved verses, reading-plan progress — get written from outside the chapter on screen (a detail sheet, a highlights list, and later Chat via an event-bus projection into `bible.sqlite`), so the chapter renderer **must** bind those through GRDBQuery `@Query` over the decoration tables, layered over the static text. See root AGENTS.md §Persistence for the full rule.
- **Snapshot tests** land in the same PR as the view they cover. Per root AGENTS.md §Testing.2: light/dark/sepia × default/Dynamic Type XXL for any view-level change, recorded against CI's Xcode 26.4.1 + iOS 26.4 + iPhone 17 pin.
- **Coverage target ≥70%** per root AGENTS.md.

## Tests

`swift test` from `Packages/Bible/` must be green before any PR opens. Snapshot fixtures live in `Tests/BibleTests/UI/Snapshots/__Snapshots__/`.
