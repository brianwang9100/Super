# Bible — Agent Guidelines

The Bible mini-applet: a chapter-reading surface with verse selection, highlights, book/chapter and translation pickers.

## What lives here (incremental — builds out per the plan)

- **Applet** (`Applet/`): `BibleApplet` — `MiniApplet` conformance, applet id `"bible"`. `BibleBookmarksApplet` — a second `MiniApplet` (id `"bookmarks"`, SuperBible-only) listing the six chapter-bookmark slots; built via `BibleApplet.makeBookmarksApplet()`, which hands it the reader's read-only `DatabaseContext` so it shares `bible.sqlite` without leaking `BibleDatabase`.
- **Models** (`Models/`): plain data — `BibleBook`/`BibleChapter`/`BibleParagraph`/`BibleVerse` (decoded text), `BiblePosition`/`BibleChapterDirection`/`BibleBookSummary`/`BibleBookCatalog`/`BibleBookOrder`/`BibleTranslation` (navigation), `BibleHighlightColor` (the five-colour palette), `BibleBookmarkColor` (the six fixed chapter-bookmark slots), and the `BibleReadingPositionRecord` / `BibleHighlightRecord` / `BibleBookmarkRecord` GRDB records.
- **Database** (`Database/`): `BibleDatabase` — wraps the `bible.sqlite` `DatabaseQueue` and the schema migrator.
- **Repositories** (`Repositories/`): protocol seam + `GRDB`-prefixed impl, one pair per record.
- **Queries** (`Queries/`): GRDBQuery `ValueObservationQueryable` requests — `ChapterHighlightsRequest` is what the chapter renderer's `@Query` observes.
- **TextSources** (`TextSources/`): `BibleTextLoader` protocol (`loadChapter(bookId:chapterNumber:translation:)`) + `DatabaseBibleTextLoader`, which reads one structured chapter at a time from the prebuilt, read-only `bible-text.sqlite` (also home to the `bible.search` FTS index — see `BibleTextSearching`). `BibleTextDatabase` owns that bundled queue. The per-book JSON for WEB / KJV / ASV / BSB is **no longer shipped**: it lives in the test target (`Tests/BibleTests/Fixtures/Text/`, one `<CODE>-<bookID>.json` each) as the parity oracle that `Scripts/generate_bible_text_sqlite.py` builds the sqlite from (regenerate + commit the sqlite when the JSON changes). `BundledBibleTextLoader` (the JSON loader) is now a test-only helper under `Tests/.../Support/`. The `Scripts/generate_translation_json.py` converter regenerates the JSON from USFM (WEB / KJV / ASV from eBible.org; BSB from bereanbible.com).
- **Formatting** (`Formatting/`): pure, view-free text rendering — `BibleCitationFormatter` compresses contiguous verse runs to ranges (`"4-6, 9"`); `BibleVerseAnnouncement` builds the VoiceOver label a verse span speaks; `VerseTokenizer` breaks verse fragments into the per-word tokens `VerseFlowLayout` reflows (kept off the `View` layer so the pure tokenizing stays nonisolated and testable).
- **Clipboard** (`Clipboard/`): `ClipboardWriter` protocol + `SystemClipboard` — the injectable seam the reader's Copy action writes through.
- **ViewModels** (`ViewModels/`): `@Observable @MainActor` view models, one per screen or sheet.
- **UI** (`UI/`): SwiftUI views. **Before naming a new view, read [`docs/NAMING_CONVENTIONS.md` Part 4](../../docs/NAMING_CONVENTIONS.md#part-4--swiftui-view-layer-chat-applet).** Drop the `View` suffix, one struct per file, bucket suffix per the doc (`*Screen`, `*Sheet`, `*Bar`, `*Block`, `*Toast`, `*Bubble`, `*Footer`); composed strips inside the screen are Regions with a bare role name. `VerseFlowLayout` is the custom `Layout` that reflows tappable verse words. `BibleChapterReader` (a Region) owns the highlight `@Query`; `BibleScreen` injects the `DatabaseContext` and gives the reader a fresh identity per chapter so the constant request always matches the on-screen position. `BibleSheetMotion` resolves the Reduce Motion setting into the sheet animation + transition.

## Bible-specific rules

Root [`../../AGENTS.md`](../../AGENTS.md) carries the shared rules. Bible-specific additions:

- **Record / view-model / repository shape.** Records add `Equatable, Identifiable` on top of root's four protocols (for `ForEach` diffing and test equality). View models named `*ScreenViewModel` / `*SheetViewModel`. Repositories are a protocol seam + `GRDB`-prefixed concrete impl.
- **Cross-applet hand-off uses generic `RecordReference`.** The action sheet's "Add to chat" / "New chat" rows publish on Core's `SuperEventBus` (`BibleScreen.addSelectionToChat`); Chat consumes it. Never reach into Chat types directly.
- **`+` whole-chapter hand-off is still deferred.** The action sheet's verse-selection chat rows are live, but the `+` nav button's whole-chapter hand-off remains a "coming soon" toast (`presentChatComingSoon`) — a whole-chapter snapshot would be unbounded. (The floating "Ask about this chapter…" bubble was dropped — it duplicated the shell's chat composer.)
- **Reactive vs. imperative reads — split by data source.** Chapter *text* is a bundled static resource and reading position is single-writer (only the Bible screen writes it): both stay imperative `@Observable` view model loads — do not reactive-ify them. *Decorations* — highlights, saved verses, reading-plan progress — get written from outside the chapter on screen (a detail sheet, a highlights list, and later Chat via an event-bus projection into `bible.sqlite`), so the chapter renderer **must** bind those through GRDBQuery `@Query` over the decoration tables, layered over the static text.
- **Accessibility.** Every interactive element carries an `accessibilityLabel`; verse spans coalesce to one VoiceOver element per verse (the first word labels the whole verse, the rest are `accessibilityHidden`). Sheet presentation honours Reduce Motion via `BibleSheetMotion`.

## Tests

Snapshot fixtures live in `Tests/BibleTests/UI/Snapshots/__Snapshots__/`.

Module-specific test patterns (root [`AGENTS.md`](../../AGENTS.md) §Testing.7 carries the shared rules):

- **Gated/scripted generators** — `FakeBibleAnnotateGenerator` is the reference for proving single-flight and landing a cancel mid-flight without sleeps: `ScriptedBibleAnnotateGenerator` `fatalError`s on over-call; `GatedBibleAnnotateGenerator` exposes `releaseNext`/`awaitCall` and a `maxInFlight` high-water mark.
- **Synchronous stream seam** — state-bearing tests of a stream consumer drive it through the controller's `_simulateEvent(_:)` seam, not by yielding through the fake's `AsyncStream` and polling. Drain view-model async paths via their `_waitForPending*` seams before asserting.
