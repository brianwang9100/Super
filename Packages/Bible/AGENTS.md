# Bible

- Chapter text comes from bundled, read-only `bible-text.sqlite`; user state lives in `bible.sqlite`. After changing the translation JSON fixtures in `Tests/BibleTests/Fixtures/Text/`, regenerate and commit the text database with `Scripts/generate_bible_text_sqlite.py`. `Scripts/generate_translation_json.py` converts the upstream USFM sources; JSON is a test oracle, not a shipped resource.
- Chapter text and single-writer reading position use imperative loads. Decorations (highlights, saved verses, plan progress) use GRDBQuery `@Query` because other surfaces can write them. `BibleScreen` supplies the database context and a fresh reader identity per chapter so the request matches the displayed chapter.
- Build the Bookmarks applet through `BibleApplet.makeBookmarksApplet()` so it shares the reader's read-only database context without exposing `BibleDatabase`.
- Selection handoffs to Chat use Core's `RecordReference` and event bus. Whole-chapter handoff remains deferred; do not restore the redundant floating chat-composer bubble.
- Verse words coalesce into one VoiceOver element per verse: the first word labels the verse, remaining words are accessibility-hidden. Interactive controls need accessible names; supply `accessibilityLabel` for custom or gesture-driven elements without a native label. Sheet motion uses `BibleSheetMotion`.
- Bible records additionally conform to `Equatable, Identifiable`; repository implementations use the `GRDB` prefix.

For annotation concurrency tests, use `ScriptedBibleAnnotateGenerator` or `GatedBibleAnnotateGenerator` (`awaitCall`/`releaseNext`). Drive narration state through `_simulateEvent(_:)` and drain view-model `_waitForPending*` seams before asserting.
