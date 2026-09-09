# Bible navigation history design

Status: native prototype approved; production implementation and PR authorized September 8, 2026.

## Behavior

Keep a browser-style sequence of at most **25 chapter visits, including the current visit**. A cursor points into the sequence. The sequence is ordered by navigation, not by biblical order or timestamp.

Example: `1 Peter 2 → John 3 → Psalm 23`. Back opens John 3; forward returns to Psalm 23. After going back to John 3, opening Romans 8 produces `1 Peter 2 → John 3 → Romans 8`. Psalm 23 is removed from forward history.

| Action | History effect |
|---|---|
| Open a different chapter using the book picker | Discard forward entries, append destination |
| Previous/next chapter from the toolbar, footer, or composer accessory | Same append behavior |
| Open a different chapter from a bookmark, Chat citation, or incoming reference | Same append behavior through the existing reference route |
| Back / forward | Move the cursor one entry; never append or prune |
| Select the already current chapter | No history change; dismiss the picker normally |
| Open another verse within the current chapter | Preserve the sequence and cursor; retain existing verse selection/scroll behavior |
| Change translation | Preserve the sequence and cursor |
| Reopen a chapter visited earlier, after visiting another chapter | Append another visit; do not globally deduplicate |
| Invalid book/chapter/reference rejected by existing validation | No history change, including no forward pruning |
| Valid chapter whose bundled text is unavailable | Record the destination and show the existing unavailable state; back still works |
| Relaunch or return to the applet | Restore the sequence and cursor; do not append |

When appending entry 26, remove the oldest entry and adjust the cursor. Apply forward truncation before the cap. Disable back at index zero and forward at the last index; retain both buttons and their space even when disabled. An empty/new installation becomes one entry at its initial chapter.

**Translation policy:** back/forward keeps the reader's current translation. This is chapter history; translation remains a reader preference.

**Landing behavior:** return to the chapter's top. Do not restore verse selection, scroll offsets, sheets, or narration. Verse-specific incoming references retain their existing landing behavior. Per-visit scroll restoration is a possible follow-up, not part of this chapter-level feature.

## Selector design

Place two independent chevron buttons inside the existing selector's leading edge:

```text
[  ‹    ›  |  1 Peter 2  |  KJV ⌄  ]
   Back Forward   Book      Translation
```

The new divider sits immediately left of the book segment, separating the arrow pair from the existing book/translation selector. Keep the existing divider between book and translation. There is no divider between the two arrows.

- Use a single `superGlassSurface(in: RoundedRectangle(cornerRadius: 22))` for the grouped selector. This retains the pill silhouette at ordinary height and accommodates wrapped rows.
- Each history button uses a compact 32 × 44 pt hit area. Use SF Symbols `chevron.left` and `chevron.right`, about 14–16 pt medium weight through `SuperTypography`.
- Per the native spacing feedback, the pair occupies **64 pt** with glyphs **28 pt center-to-center**: shift each glyph 2 pt toward the pair's center. This removes 12 pt from each outer margin of the previous 88 pt pair while retaining its inter-chevron spacing. Keep button frames/content shapes adjacent and non-overlapping; the narrower horizontal tap regions are intentional for this compact design. Use the same spacing for enabled and disabled states.
- Use theme ink for enabled chevrons and 0.35 opacity for disabled chevrons. Disabled controls cannot activate. Divider: existing 1 × 16 pt treatment with the existing border token/opacity.
- Keep the book and translation segments separately tappable. A tap on a history button must not open either picker.
- Accessibility labels: “Go back” / “Go forward”; destination hints such as “John, chapter 3.” Expose disabled state. Preserve full book names in accessibility labels even if visually abbreviated.
- Match existing selection haptics and Reduced Motion behavior. No long-press history menu, swipe gesture, count badge, or history list in the shipping toolbar.
- At normal widths, retain the centered one-row selector between the shell hamburger and chapter-actions control. Use the full book label, with the approved wrapping fallback when necessary. Keep 32 × 44 pt history targets and 44 × 44 pt utility targets.
- At large app font scale or Dynamic Type, move the selector to a centered full-width row beneath the utility buttons. Allow the book label to wrap and the selector height to grow, with a rounded-rectangle glass shape if needed. At the largest sizes, place translation on a second line within the same surface, separated horizontally. Never shrink text to cancel accessibility scaling, overlap controls, or reduce hit targets.
- Feed the measured toolbar height into the reader's top content reserve and immersive hide distance. Replace the fixed 68 pt reader inset and 120 pt hide offset; preserve the ordinary layout's visual spacing, avoid safe-area double counting, and recompute for width/font changes. Expanded chrome must clear the chapter heading and slide fully offscreen.

### Existing chapter controls

History arrows mean “where I was,” while existing chapter arrows mean previous/next chapter in biblical order. `BibleScreen` already distinguishes hosts: SuperBible places chapter stepping above the minimized composer; SuperOS places it around the selector. Keep those actions intact. Show history inside the normal book/translation selector in both hosts. In SuperOS, use the full-width selector fallback when the extra chapter arrows make the center too narrow, moving chapter stepping to the utility row. Existing SuperOS selection mode continues to replace the selector with the selection pill; history becomes available again when selection clears. SuperBible retains the selector during selection as it already does.

## Architecture and offline storage

Keep everything in `Packages/Bible`. `BibleScreenViewModel` owns navigation and exposes history availability. No cross-applet database access, new module, global singleton, network call, or cloud synchronization.

A pure `BibleNavigationHistory` value plus an optional versioned JSON column on the existing singleton `bibleReadingPosition` row. Persist chapter, translation, history entries, and history cursor in one row write through `BibleReadingPositionRepository`. This preserves the existing tool translation lookup and avoids separate writes drifting out of sync.

Alternatives considered:

1. **Separate visit and cursor tables:** useful for searchable/unbounded history; unnecessary joins and migration machinery for 25 entries that have one owner.
2. **Preferences/UserDefaults blob:** easy to start, but splits reader state across stores and loses atomicity with the existing GRDB position row.

### Data shape

Add `Codable` to `BiblePosition`. Add a value type with private mutation, `entries: [BiblePosition]`, `currentIndex: Int`, a constant `capacity = 25`, `current`, `canGoBack`, `canGoForward`, and `visit`, `goBack`, `goForward` operations. Visits do not require timestamps or generated IDs: duplicates are distinguished by their positions in the array.

Persist `navigationHistoryJSON: String?` on `BibleReadingPositionRecord`, with a default of nil in its initializer for existing callers. JSON is a versioned envelope:

```json
{"version":1,"entries":[{"bookId":"1PE","chapterNumber":2},{"bookId":"JHN","chapterNumber":3}],"currentIndex":1}
```

Decode the JSON separately from GRDB row decoding, so malformed history does not prevent restoration of a valid legacy chapter/translation. Append migration `v13_navigationHistory` (or the next free number if implementation begins after another migration lands):

```sql
ALTER TABLE bibleReadingPosition ADD COLUMN navigationHistoryJSON TEXT;
```

Validate version, nonempty entries, count ≤25, cursor bounds, catalog-valid chapter destinations, and equality between the pointed-to entry and the row's book/chapter. A missing, malformed, unsupported, or inconsistent history payload seeds a single-entry history from a valid saved chapter; an invalid saved chapter falls back to the existing default. Repair by saving a complete valid record after load. Do not erase unrelated data or invent a visit timestamp ordering.

### Navigation and lifecycle

Route `stepChapter`, `selectChapter`, and `openReference` through one validated chapter transition. Carry intent explicitly so history traversal cannot accidentally call the append path. Keep reference-specific selection handling separate. On traversal, stop narration, clear selection and stale `pendingScrollVerse`, dismiss chapter-bound presentation state, reset immersive/footer state, load the target chapter, and persist the new cursor.

Restore once per view-model lifetime. The restore gate starts at initialization, so references received before the first load are queued too. Initial load and retries are single-flight; intents arriving during a retry are queued and drained after recovery. While the initial load is unresolved, disable user chapter/history/translation controls and queue incoming reference or programmatic translation intents in order; drain after restoration. Background flush awaits restoration before writing. Subsequent `load()` calls share/await the original load, rather than reading old persisted state over live navigation. Test this with a gated repository, without timed sleeps.

Distinguish a missing row, malformed payload in a successfully read row, and a repository read error. Only the first two allow an automatic seed/repair write. A transient read failure must not overwrite disk history with the default. Keep reading available with temporary in-memory history and surface a retry action; suppress persistence of provisional navigation/translation until a successful retry. On retry success, restore the disk sequence; if the user navigated provisionally, append only the currently displayed resolved chapter using normal visit semantics, then apply the latest explicitly chosen translation if any. Intermediate temporary visits are omitted during recovery. Do not replay relative chapter steps or back/forward commands against a different recovered sequence. This keeps the visible destination when retry follows a provisional Back and does not resurrect discarded provisional forward entries. Test read failure followed by successful restoration with and without intervening navigation, including `A→B→C→Back→D` and retry immediately after Back. When no repository exists at all, session-only history stays usable without a retry loop.

Continue the existing chained `persistTask` approach: capture an immutable full-state record before creating a task, await the prior write, then save. `_waitForPendingPersist()` drains the chain. A single atomic write protects history/current-position consistency. Translation-only writes include the unchanged history payload.

Writes run immediately after navigation, without a debounce. Background transitions should await the current chain through a lifecycle method; platform suspension can still interrupt unfinished I/O. Durability means the last successfully committed full record survives relaunch, with no split cursor/history state. On database unavailability, allow session history in memory. On a write error, retain in-memory history and the last committed disk snapshot, report a restrained “Navigation history couldn't be saved” message using existing transient UI, and retry the full current state on the next navigation or background flush. Do not log visited chapters in diagnostics.

## Validation and risks

- Pure value tests: cursor bounds, forward truncation, cap including current, no-op same chapter, duplicate visits, revisiting a former forward destination as a new visit, and Codable round trips.
- Persistence tests: release-shaped v12→v13 upgrade preserving existing data, atomic round trip, malformed/unsupported/mismatched payload recovery, and close/reopen a temporary on-disk database while the cursor has forward entries.
- View-model tests: all navigation sources, translation policy, verse-only navigation, invalid references, missing text, traversal cleanup, rapid mixed navigation/write ordering, initial-load races, idempotent reload, and failure recovery. Inject Core's clock and use awaitable seams.
- UI: reuse existing `BibleNavBarSnapshotTests` and reader captures for Vellum light/dark, SuperOS/SuperBible, selection, and font scaling. Add only a compact history-state gallery and a narrow/large-type case if existing captures cannot show those risks. Register inventory changes; Argos is the image baseline store.
- Manual simulator: ensure buttons hit independently, VoiceOver names destinations and disabled states, long names and font-scale extremes fit, narration stops, incoming references work, and relaunch after going back retains forward navigation in airplane mode.

The main risks are confusing history with chapter stepping, squeezing the top bar, a restoration task overwriting a newer intent, and saving mismatched position/cursor state. The explicit actions, layout fallbacks, restore gate, and atomic full-record writes address them.

## Prototype to production

The approved prototype established the compact arrow spacing and grouped selector. Production uses the native controls, GRDB persistence, and explicit view-model navigation described above. The explanatory prototype history strip and debug-only route are absent from the shipping app.
